require "set"
require "colorize"
require "../syntax/ast"

module Crystal
  def self.print_hierarchy(program, exp)
    HierarchyPrinter.new(program, exp).execute
  end

  class HierarchyPrinter
    def initialize(@program : Program, exp : String?)
      @exp = exp ? Regex.new(exp) : nil
      @indents = [] of Bool
      @targets = Set(Type).new
      @llvm_typer = LLVMTyper.new(@program)
    end

    def execute
      if exp = @exp
        compute_targets(@program.types, exp, false)
      end

      with_color.light_gray.bold.push(STDOUT) do
        print_type @program.object
      end
    end

    def compute_targets(types : Array, exp, must_include = false)
      outer_must_include = must_include
      types.each do |type|
        must_include |= compute_target type, exp, outer_must_include
      end
      must_include
    end

    def compute_targets(types : Hash, exp, must_include = false)
      outer_must_include = must_include
      types.each_value do |type|
        must_include |= compute_target type, exp, outer_must_include
      end
      must_include
    end

    def compute_target(type : NonGenericClassType, exp, must_include)
      if must_include || (type.full_name =~ exp)
        @targets << type
        must_include = true
      end

      compute_targets type.types, exp, false

      subtypes = type.subclasses.select { |sub| !sub.is_a?(GenericClassInstanceType) }
      must_include |= compute_targets subtypes, exp, must_include
      if must_include
        @targets << type
      end
      must_include
    end

    def compute_target(type : GenericClassType, exp, must_include)
      if must_include || (type.full_name =~ exp)
        @targets << type
        must_include = true
      end

      compute_targets type.types, exp, false
      compute_targets type.generic_types, exp, must_include

      subtypes = type.subclasses.select { |sub| !sub.is_a?(GenericClassInstanceType) }
      must_include |= compute_targets subtypes, exp, must_include
      if must_include
        @targets << type
      end
      must_include
    end

    def compute_target(type : GenericClassInstanceType, exp, must_include)
      if must_include
        @targets << type
        must_include = true
      end
      must_include
    end

    def compute_target(type, exp, must_include)
      false
    end

    def print_subtypes(types)
      types = types.sort_by &.to_s
      types.each_with_index do |type, i|
        if i == types.size - 1
          @indents[-1] = false
        end
        print_subtype type
      end
    end

    def print_subtype(type)
      return unless must_print? type

      unless @indents.empty?
        print_indent
        print "|"
        puts
      end

      print_type type
    end

    def print_type_name(type)
      print_indent
      print "+" unless @indents.empty?
      print "- "
      print type.struct? ? "struct" : "class"
      print " "
      print type

      if (type.is_a?(NonGenericClassType) || type.is_a?(GenericClassInstanceType)) &&
         !type.is_a?(PointerInstanceType) && !type.is_a?(ProcInstanceType)
        size = @llvm_typer.size_of(@llvm_typer.llvm_struct_type(type))
        with_color.light_gray.push(STDOUT) do
          print " ("
          print size.to_s
          print " bytes)"
        end
      end
      puts
    end

    def print_type(type : NonGenericClassType | GenericClassInstanceType)
      print_type_name type

      subtypes = type.subclasses.select { |sub| must_print?(sub) }
      print_instance_vars type, !subtypes.empty?

      with_indent do
        print_subtypes subtypes
      end
    end

    def print_type(type : GenericClassType)
      print_type_name type

      subtypes = type.subclasses.select { |sub| must_print?(sub) }
      print_instance_vars type, !subtypes.empty?

      with_indent do
        print_subtypes subtypes
      end
    end

    def print_type(type)
      # Nothing to do
    end

    def print_instance_vars(type : GenericClassType, has_subtypes)
      instance_vars = type.declared_instance_vars
      return unless instance_vars

      max_name_size = instance_vars.keys.max_of &.size

      instance_vars.each do |name, types|
        print_indent
        print (@indents.last ? "|" : " ")
        if has_subtypes
          print "  .   "
        else
          print "      "
        end

        with_color.light_gray.push(STDOUT) do
          print name.ljust(max_name_size)
          next if types.size == 0
          print " : "
          print types.join " | "
        end
        puts
      end
    end

    def print_instance_vars(type, has_subtypes)
      instance_vars = type.instance_vars
      return if instance_vars.empty?

      instance_vars = instance_vars.values
      typed_instance_vars = instance_vars.select &.type?

      max_name_size = instance_vars.max_of &.name.size

      if typed_instance_vars.empty?
        max_type_size = 0
        max_bytes_size = 0
      else
        max_type_size = typed_instance_vars.max_of &.type.to_s.size
        max_bytes_size = typed_instance_vars.max_of { |var| @llvm_typer.size_of(@llvm_typer.llvm_embedded_type(var.type)).to_s.size }
      end

      instance_vars.each do |ivar|
        print_indent
        print (@indents.last ? "|" : " ")
        if has_subtypes
          print "  .   "
        else
          print "      "
        end

        with_color.light_gray.push(STDOUT) do
          print ivar.name.ljust(max_name_size)
          print " : "
          if ivar_type = ivar.type?
            print ivar_type.to_s.ljust(max_type_size)
            size = @llvm_typer.size_of(@llvm_typer.llvm_embedded_type(ivar_type))
            with_color.light_gray.push(STDOUT) do
              print " ("
              print size.to_s.rjust(max_bytes_size)
              print " bytes)"
            end
          else
            print "MISSING".colorize.red.bright
          end
        end
        puts
      end
    end

    def must_print?(type : NonGenericClassType)
      !(@exp && !@targets.includes?(type))
    end

    def must_print?(type : GenericClassType)
      !(@exp && !@targets.includes?(type))
    end

    def must_print?(type)
      false
    end

    def print_indent
      unless @indents.empty?
        print "  "
        0.upto(@indents.size - 2) do |i|
          indent = @indents[i]
          if indent
            print "|  "
          else
            print "   "
          end
        end
      end
    end

    def with_indent
      @indents.push true
      yield
      @indents.pop
    end

    def with_color
      ::with_color.toggle(@program.color?)
    end
  end
end
