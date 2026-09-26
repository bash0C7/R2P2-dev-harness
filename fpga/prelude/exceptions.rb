# 例外 (docs/spec.md §10「例外」)。Exception は組み込みのクラス (番号 15) で、ほかはここで Ruby のクラスとして作る。
# 投げるのは primitive の __raise、捕まえるのはコアが例外の表 (catch handler) を引いてする。
# 表示は PicoRuby に合わせる: inspect はメッセージが無ければクラスの名前、あれば #<クラス: メッセージ>

class Exception
  def initialize(message = nil)
    @message = message
  end

  def self.exception(*args)
    new(*args)
  end

  def exception(*args)
    return self if args.empty?
    self.class.new(*args)
  end

  def to_s
    @message.nil? ? self.class.name : @message.to_s
  end

  def message
    to_s
  end

  def inspect
    m = to_s
    m.empty? || @message.nil? ? self.class.name : "#<#{self.class.name}: #{m}>"
  end
end

class ScriptError < Exception; end
class NotImplementedError < ScriptError; end
class StandardError < Exception; end
class RuntimeError < StandardError; end
class FrozenError < RuntimeError; end
class ArgumentError < StandardError; end
class TypeError < StandardError; end
class NameError < StandardError; end
class NoMethodError < NameError; end
class ZeroDivisionError < StandardError; end
class IndexError < StandardError; end
class KeyError < IndexError; end
class StopIteration < IndexError; end
class RangeError < StandardError; end
class FloatDomainError < RangeError; end
class LocalJumpError < StandardError; end

class Object
  # raise / raise "msg" / raise Cls / raise Cls, "msg" / raise obj。引数なしは今 rescue している例外 ($!) を投げ直す
  def raise(*args)
    if args.empty?
      e = $!
      e = RuntimeError.new("unhandled exception") if e.nil?
    elsif args[0].class == String
      __raise_arguments_are_not_supported if args.size > 1
      e = RuntimeError.new(args[0])
    else
      __raise_arguments_are_not_supported if args.size > 2
      e = args.size == 1 ? args[0].exception : args[0].exception(args[1])
    end
    __raise(TypeError.new("exception class/object expected")) unless e.is_a?(Exception)
    __raise(e)
  end
end

class Integer
  # コアの実行時エラー (受け手は種類、isa.rb の CERR_*)。メッセージは PicoRuby の形
  def __core_error(detail, other)
    e = if self == 1
          ZeroDivisionError.new("divided by 0")
        elsif self == 2
          NoMethodError.new("undefined method '#{detail}' for #{other.class}")
        elsif self == 3
          ArgumentError.new("wrong number of arguments (given #{detail}, expected #{other})")
        elsif self == 4
          TypeError.new("#{detail.nil? ? 'nil' : detail.class} can't be coerced into #{other.class}")
        elsif self == 5
          ArgumentError.new("comparison of #{other.class} with #{detail.nil? ? 'nil' : detail.class} failed")
        elsif self == 6
          FloatDomainError.new(detail.to_s)
        else
          RangeError.new("float #{detail} out of range of integer")
        end
    __raise(e)
  end
end
