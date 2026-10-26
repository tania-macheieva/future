# frozen_string_literal: true

require 'monitor'

class Future
  class TimeoutError < StandardError; end

  # Виконує fn в окремому потоці й одразу повертає Future.
  def self.submit(fn)
    future = new
    Thread.new do
      Thread.current.report_on_exception = false
      begin
        future.fulfill(fn.call)
      rescue StandardError => e
        future.reject(e)
      end
    end
    future
  end

  # Fulfilled, коли виконано всі; rejected одразу, щойно відхилено будь-який.
  # Значення повертаються в порядку вхідних Future.
  def self.all(futures)
    result = new
    return result.tap { |r| r.fulfill([]) } if futures.empty?

    values = Array.new(futures.size)
    remaining = futures.size
    lock = Mutex.new

    futures.each_with_index do |future, index|
      future.then do |value|
        done = lock.synchronize do
          values[index] = value
          (remaining -= 1).zero?
        end
        result.fulfill(values) if done
      end
      future.catch { |error| result.reject(error) }
    end
    result
  end

  # Приймає стан першого завершеного Future (значення або помилку).
  def self.race(futures)
    raise ArgumentError, 'race needs at least one future' if futures.empty?

    result = new
    futures.each do |future|
      future.then { |value| result.fulfill(value) }
      future.catch { |error| result.reject(error) }
    end
    result
  end

  def initialize
    @lock = Monitor.new
    @cond = @lock.new_cond
    @state = :pending
    @callbacks = []
  end

  # Стан встановлюється лише один раз: повторні fulfill/reject ігноруються (повертають false).
  def fulfill(value)
    settle(:fulfilled, value, nil)
  end

  def reject(error)
    settle(:rejected, nil, error)
  end

  def pending?
    @lock.synchronize { @state == :pending }
  end

  def fulfilled?
    @lock.synchronize { @state == :fulfilled }
  end

  def rejected?
    @lock.synchronize { @state == :rejected }
  end

  # Нове Future з результатом block(value). Помилка пропагується далі без виклику block.
  def then(&block)
    child = Future.new
    on_settle do
      if @state == :fulfilled
        child.complete_with { block.call(@value) }
      else
        child.reject(@error)
      end
    end
    child
  end

  # Обробка помилки: block(error) стає значенням нового Future. Успіх проходить без змін.
  def catch(&block)
    child = Future.new
    on_settle do
      if @state == :rejected
        child.complete_with { block.call(@error) }
      else
        child.fulfill(@value)
      end
    end
    child
  end
  alias on_error catch

  # Блокує до завершення. Повертає значення або кидає помилку Future.
  # Після timeout секунд кидає TimeoutError (стан Future не змінюється).
  def get(timeout = nil)
    @lock.synchronize do
      deadline = timeout && now + timeout
      while @state == :pending
        remaining = deadline && deadline - now
        raise TimeoutError, "future not completed within #{timeout} s" if remaining && remaining <= 0

        @cond.wait(remaining)
      end
    end

    raise @error if @state == :rejected

    @value
  end
  alias await get

  protected

  def complete_with
    fulfill(yield)
  rescue StandardError => e
    reject(e)
  end

  private

  def settle(state, value, error)
    callbacks = nil
    @lock.synchronize do
      return false unless @state == :pending

      @state = state
      @value = value
      @error = error
      callbacks = @callbacks
      @callbacks = []
      @cond.broadcast
    end
    callbacks.each(&:call)
    true
  end

  def on_settle(&callback)
    run_now = @lock.synchronize do
      @callbacks << callback if @state == :pending
      @state != :pending
    end
    callback.call if run_now
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
