# frozen_string_literal: true

require_relative 'future'

RSpec.describe Future do
  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def failed(message = 'boom')
    described_class.new.tap { |f| f.reject(RuntimeError.new(message)) }
  end

  describe 'successful execution' do
    it 'delivers the value computed by submit' do
      expect(described_class.submit(-> { 21 * 2 }).get(1)).to eq(42)
    end

    it 'blocks get until the value is ready' do
      future = described_class.submit(-> { sleep(0.05); :done })

      time = elapsed { expect(future.get(1)).to eq(:done) }

      expect(time).to be >= 0.04
      expect(future).to be_fulfilled
    end

    it 'transforms the value with then, also in a chain' do
      future = described_class.submit(-> { 2 }).then { |x| x + 1 }.then { |x| x * 10 }

      expect(future.get(1)).to eq(30)
    end

    it 'runs then at once on an already fulfilled future' do
      future = described_class.new.tap { |f| f.fulfill(5) }

      expect(future.then { |x| x * 2 }.get(1)).to eq(10)
    end

    it 'passes the value through catch unchanged' do
      expect(described_class.submit(-> { :ok }).catch { :recovered }.get(1)).to eq(:ok)
    end
  end

  describe 'error propagation' do
    it 'raises the original error from get' do
      future = described_class.submit(-> { raise ArgumentError, 'bad' })

      expect { future.get(1) }.to raise_error(ArgumentError, 'bad')
      expect(future).to be_rejected
    end

    it 'skips then and propagates the error down the chain' do
      called = false
      future = failed.then { called = true }.then { called = true }

      expect { future.get(1) }.to raise_error('boom')
      expect(called).to be(false)
    end

    it 'recovers with catch / on_error' do
      expect(failed.catch { |e| "handled #{e.message}" }.get(1)).to eq('handled boom')
      expect(failed.on_error { :fallback }.get(1)).to eq(:fallback)
    end

    it 'rejects the result when the then block raises' do
      future = described_class.submit(-> { 1 }).then { raise 'in then' }

      expect { future.get(1) }.to raise_error('in then')
    end
  end

  describe 'single settlement' do
    it 'keeps the first outcome and ignores later ones' do
      future = described_class.new

      expect(future.fulfill(:first)).to be(true)
      expect(future.fulfill(:second)).to be(false)
      expect(future.reject(RuntimeError.new('late'))).to be(false)
      expect(future.get(1)).to eq(:first)
    end
  end

  describe '.all' do
    it 'waits for every future and keeps the input order' do
      a = described_class.new
      b = described_class.new
      all = described_class.all([a, b])

      b.fulfill(:b)
      expect(all).to be_pending

      a.fulfill(:a)
      expect(all.get(1)).to eq(%i[a b])
    end

    it 'is rejected at once when any future fails, without waiting for the rest' do
      never = described_class.new
      all = described_class.all([never, failed('one failed')])

      expect { all.get(1) }.to raise_error('one failed')
    end

    it 'is fulfilled with an empty array for no futures' do
      expect(described_class.all([]).get(1)).to eq([])
    end

    it 'runs submitted futures in parallel' do
      futures = Array.new(4) { |i| described_class.submit(-> { sleep(0.1); i }) }

      time = elapsed { expect(described_class.all(futures).get(2)).to eq([0, 1, 2, 3]) }

      expect(time).to be < 0.3
    end
  end

  describe '.race' do
    it 'takes the first completed future' do
      a = described_class.new
      b = described_class.new
      race = described_class.race([a, b])

      b.fulfill(:b)
      a.fulfill(:a)

      expect(race.get(1)).to eq(:b)
    end

    it 'does not wait for slower futures' do
      fast = described_class.submit(-> { sleep(0.02); :fast })
      slow = described_class.submit(-> { sleep(0.5); :slow })

      time = elapsed { expect(described_class.race([slow, fast]).get(1)).to eq(:fast) }

      expect(time).to be < 0.3
    end

    it 'takes the error if the first completed future failed' do
      race = described_class.race([described_class.new, failed('first failed')])

      expect { race.get(1) }.to raise_error('first failed')
    end

    it 'rejects an empty list' do
      expect { described_class.race([]) }.to raise_error(ArgumentError)
    end
  end

  describe 'get with timeout' do
    it 'raises TimeoutError when the value is not ready in time' do
      future = described_class.submit(-> { sleep(2) })

      time = elapsed { expect { future.get(0.05) }.to raise_error(described_class::TimeoutError) }

      expect(time).to be_between(0.05, 0.5)
    end

    it 'does not change the state: the value can be fetched later' do
      future = described_class.submit(-> { sleep(0.15); :late })

      expect { future.get(0.02) }.to raise_error(described_class::TimeoutError)
      expect(future).to be_pending
      expect(future.get(2)).to eq(:late)
    end

    it 'returns the value if it arrives within the timeout' do
      future = described_class.submit(-> { sleep(0.02); :in_time })

      expect(future.get(1)).to eq(:in_time)
    end
  end
end
