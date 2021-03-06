module Printf
using Base.Grisu
export @printf, @sprintf

### printf formatter generation ###
const SmallFloatingPoint = Union(Float64,Float32,Float16)
const SmallNumber = Union(SmallFloatingPoint,Base.Signed64,Base.Unsigned64,Uint128,Int128)

function gen(s::String)
    args = {}
    blk = Expr(:block, :(local neg, pt, len, exp, do_out, args))
    for x in parse(s)
        if isa(x,String)
            push!(blk.args, :(write(out, $(length(x)==1 ? x[1] : x))))
        else
            c = lowercase(x[end])
            f = c=='f' ? gen_f :
                c=='e' ? gen_e :
                c=='g' ? gen_g :
                c=='c' ? gen_c :
                c=='s' ? gen_s :
                c=='p' ? gen_p :
                         gen_d
            arg, ex = f(x...)
            push!(args, arg)
            push!(blk.args, ex)
        end
    end
    push!(blk.args, :nothing)
    return args, blk
end

### printf format string parsing ###

function parse(s::String)
    # parse format string in to stings and format tuples
    list = {}
    i = j = start(s)
    while !done(s,j)
        c, k = next(s,j)
        if c == '%'
            isempty(s[i:j-1]) || push!(list, s[i:j-1])
            flags, width, precision, conversion, k = parse1(s,k)
            '\'' in flags && error("printf format flag ' not yet supported")
            conversion == 'a'    && error("printf feature %a not yet supported")
            conversion == 'n'    && error("printf feature %n not supported")
            push!(list, conversion == '%' ? "%" : (flags,width,precision,conversion))
            i = j = k
        else
            j = k
        end
    end
    isempty(s[i:end]) || push!(list, s[i:end])
    # coalesce adjacent strings
    i = 1
    while i < length(list)
        if isa(list[i],String)
            for j = i+1:length(list)
                if !isa(list[j],String)
                    j -= 1
                    break
                end
                list[i] *= list[j]
            end
            splice!(list,i+1:j)
        end
        i += 1
    end
    return list
end

## parse a single printf specifier ##

# printf specifiers:
#   %                       # start
#   (\d+\$)?                # arg (not supported)
#   [\-\+#0' ]*             # flags
#   (\d+)?                  # width
#   (\.\d*)?                # precision
#   (h|hh|l|ll|L|j|t|z|q)?  # modifier (ignored)
#   [diouxXeEfFgGaAcCsSp%]  # conversion

next_or_die(s::String, k) = !done(s,k) ? next(s,k) :
    error("invalid printf format string: ", repr(s))

function parse1(s::String, k::Integer)
    j = k
    width = 0
    precision = -1
    c, k = next_or_die(s,k)
    # handle %%
    if c == '%'
        return "", width, precision, c, k
    end
    # parse flags
    while c in "#0- + '"
        c, k = next_or_die(s,k)
    end
    flags = ascii(s[j:k-2])
    # parse width
    while '0' <= c <= '9'
        width = 10*width + c-'0'
        c, k = next_or_die(s,k)
    end
    # parse precision
    if c == '.'
        c, k = next_or_die(s,k)
        if '0' <= c <= '9'
            precision = 0
            while '0' <= c <= '9'
                precision = 10*precision + c-'0'
                c, k = next_or_die(s,k)
            end
        end
    end
    # parse length modifer (ignored)
    if c == 'h' || c == 'l'
        prev = c
        c, k = next_or_die(s,k)
        if c == prev
            c, k = next_or_die(s,k)
        end
    elseif c in "Ljqtz"
        c, k = next_or_die(s,k)
    end
    # validate conversion
    if !(c in "diouxXDOUeEfFgGaAcCsSpn")
        error("invalid printf format string: ", repr(s))
    end
    # TODO: warn about silly flag/conversion combinations
    flags, width, precision, c, k
end

### printf formatter generation ###

function special_handler(flags::ASCIIString, width::Int)
    @gensym x
    blk = Expr(:block)
    pad = '-' in flags ? rpad : lpad
    pos = '+' in flags ? "+" :
          ' ' in flags ? " " : ""
    abn = quote
        isnan($x) ? $(pad("NaN", width)) :
         $x < 0   ? $(pad("-Inf", width)) :
                    $(pad("$(pos)Inf", width))
    end
    ex = :(isfinite($x) ? $blk : write(out, $abn))
    x, ex, blk
end

function pad(m::Int, n, c::Char)
    if m <= 1
        :($n > 0 && write(out,$c))
    else
        @gensym i
        quote
            $i = $n
            while $i > 0
                write(out,$c)
                $i -= 1
            end
        end
    end
end

function print_fixed(out, precision, pt, ndigits)
    pdigits = pointer(DIGITS)
    if pt <= 0
        # 0.0dddd0
        write(out, '0')
        write(out, '.')
        precision += pt
        while pt < 0
            write(out, '0')
            pt += 1
        end
        write(out, pdigits, ndigits)
        precision -= ndigits
    elseif ndigits <= pt
        # dddd000.000000
        write(out, pdigits, ndigits)
        while ndigits < pt
            write(out, '0')
            ndigits += 1
        end
        write(out, '.')
    else # 0 < pt < ndigits
        # dd.dd0000
        ndigits -= pt
        write(out, pdigits, pt)
        write(out, '.')
        write(out, pdigits+pt, ndigits)
        precision -= ndigits
    end
    while precision > 0
        write(out, '0')
        precision -= 1
    end
end

function print_exp(out, exp::Integer)
    write(out, exp < 0 ? '-' : '+')
    exp = abs(exp)
    d = div(exp,100)
    if d > 0
        if d >= 10
            print(out, exp)
            return
        end
        write(out, char('0'+d))
    end
    exp = rem(exp,100)
    write(out, char('0'+div(exp,10)))
    write(out, char('0'+rem(exp,10)))
end

function gen_d(flags::ASCIIString, width::Int, precision::Int, c::Char)
    # print integer:
    #  [dDiu]: print decimal digits
    #  [o]:    print octal digits
    #  [x]:    print hex digits, lowercase
    #  [X]:    print hex digits, uppercase
    #
    # flags:
    #  (#): prefix hex with 0x/0X; octal leads with 0
    #  (0): pad left with zeros
    #  (-): left justify
    #  ( ): precede non-negative values with " "
    #  (+): precede non-negative values with "+"
    #
    x, ex, blk = special_handler(flags,width)
    # interpret the number
    prefix = ""
    if lowercase(c)=='o'
        fn = '#' in flags ? :decode_0ct : :decode_oct
    elseif c=='x'
        '#' in flags && (prefix = "0x")
        fn = :decode_hex
    elseif c=='X'
        '#' in flags && (prefix = "0X")
        fn = :decode_HEX
    else
        fn = :decode_dec
    end
    push!(blk.args, :((do_out, args) = $fn(out, $x, $flags, $width, $precision, $c)))
    ifblk = Expr(:if, :do_out, Expr(:block))
    push!(blk.args, ifblk)
    blk = ifblk.args[2]
    push!(blk.args, :((len, pt, neg) = args))
    # calculate padding
    width -= length(prefix)
    space_pad = width > max(1,precision) && '-' in flags ||
                precision < 0 && width > 1 && !('0' in flags) ||
                precision >= 0 && width > precision
    padding = nothing
    if precision < 1; precision = 1; end
    if space_pad
        if '+' in flags || ' ' in flags
            width -= 1
            if width > precision
                padding = :($width-(pt > $precision ? pt : $precision))
            end
        else
            if width > precision
                padding = :($width-neg-(pt > $precision ? pt : $precision))
            end
        end
    end
    # print space padding
    if padding != nothing && !('-' in flags)
        push!(blk.args, pad(width-precision, padding, ' '))
    end
    # print sign
    '+' in flags ? push!(blk.args, :(write(out, neg?'-':'+'))) :
    ' ' in flags ? push!(blk.args, :(write(out, neg?'-':' '))) :
                   push!(blk.args, :(neg && write(out, '-')))
    # print prefix
    for ch in prefix
        push!(blk.args, :(write(out, $ch)))
    end
    # print zero padding & leading zeros
    if space_pad && precision > 1
        push!(blk.args, pad(precision-1, :($precision-pt), '0'))
    elseif !space_pad && width > 1
        zeros = '+' in flags || ' ' in flags ? :($(width-1)-pt) : :($width-neg-pt)
        push!(blk.args, pad(width-1, zeros, '0'))
    end
    # print integer
    push!(blk.args, :(write(out, pointer(DIGITS), pt)))
    # print padding
    if padding != nothing && '-' in flags
        push!(blk.args, pad(width-precision, padding, ' '))
    end
    # return arg, expr
    :(($x)::Real), ex
end

function gen_f(flags::ASCIIString, width::Int, precision::Int, c::Char)
    # print to fixed trailing precision
    #  [fF]: the only choice
    #
    # flags
    #  (#): always print a decimal point
    #  (0): pad left with zeros
    #  (-): left justify
    #  ( ): precede non-negative values with " "
    #  (+): precede non-negative values with "+"
    #
    x, ex, blk = special_handler(flags,width)
    # interpret the number
    if precision < 0; precision = 6; end
    push!(blk.args, :((do_out, args) = fix_dec(out, $x, $flags, $width, $precision, $c)))
    ifblk = Expr(:if, :do_out, Expr(:block))
    push!(blk.args, ifblk)
    blk = ifblk.args[2]
    push!(blk.args, :((len, pt, neg) = args))
    # calculate padding
    padding = nothing
    if precision > 0 || '#' in flags
        width -= precision+1
    end
    if '+' in flags || ' ' in flags
        width -= 1
        if width > 1
            padding = :($width-(pt > 0 ? pt : 1))
        end
    else
        if width > 1
            padding = :($width-(pt > 0 ? pt : 1)-neg)
        end
    end
    # print space padding
    if padding != nothing && !('-' in flags) && !('0' in flags)
        push!(blk.args, pad(width-1, padding, ' '))
    end
    # print sign
    '+' in flags ? push!(blk.args, :(write(out, neg?'-':'+'))) :
    ' ' in flags ? push!(blk.args, :(write(out, neg?'-':' '))) :
                   push!(blk.args, :(neg && write(out, '-')))
    # print zero padding
    if padding != nothing && !('-' in flags) && '0' in flags
        push!(blk.args, pad(width-1, padding, '0'))
    end
    # print digits
    if precision > 0
        push!(blk.args, :(print_fixed(out,$precision,pt,len)))
    else
        push!(blk.args, :(write(out, pointer(DIGITS), len)))
        push!(blk.args, :(while pt >= (len+=1) write(out,'0') end))
        '#' in flags && push!(blk.args, :(write(out, '.')))
    end
    # print space padding
    if padding != nothing && '-' in flags
        push!(blk.args, pad(width-1, padding, ' '))
    end
    # return arg, expr
    :(($x)::Real), ex
end

function gen_e(flags::ASCIIString, width::Int, precision::Int, c::Char)
    # print float in scientific form:
    #  [e]: use 'e' to introduce exponent
    #  [E]: use 'E' to introduce exponent
    #
    # flags:
    #  (#): always print a decimal point
    #  (0): pad left with zeros
    #  (-): left justify
    #  ( ): precede non-negative values with " "
    #  (+): precede non-negative values with "+"
    #
    x, ex, blk = special_handler(flags,width)
    # interpret the number
    if precision < 0; precision = 6; end
    ndigits = min(precision+1,BUFLEN-1)
    push!(blk.args, :((do_out, args) = ini_dec(out,$x,$ndigits, $flags, $width, $precision, $c)))
    ifblk = Expr(:if, :do_out, Expr(:block))
    push!(blk.args, ifblk)
    blk = ifblk.args[2]
    push!(blk.args, :((len, pt, neg) = args))
    push!(blk.args, :(exp = pt-1))
    expmark = c=='E' ? "E" : "e"
    if precision==0 && '#' in flags
        expmark = string(".",expmark)
    end
    # calculate padding
    padding = nothing
    width -= precision+length(expmark)+(precision>0)+4
    # 4 = leading + expsign + 2 exp digits
    if '+' in flags || ' ' in flags
        width -= 1 # for the sign indicator
        if width > 0
            padding = quote
                padn=$width
                if (exp<=-100)|(100<=exp)
                    if isa($x,SmallNumber)
                        padn -= 1
                    else
                        padn -= Base.ndigits0z(exp) - 2
                    end
                end
                padn
            end
        end
    else
        if width > 0
            padding = quote
                padn=$width-neg
                if (exp<=-100)|(100<=exp)
                    if isa($x,SmallNumber)
                        padn -= 1
                    else
                        padn -= Base.ndigits0z(exp) - 2
                    end
                end
                padn
            end
        end
    end
    # print space padding
    if padding != nothing && !('-' in flags) && !('0' in flags)
        push!(blk.args, pad(width, padding, ' '))
    end
    # print sign
    '+' in flags ? push!(blk.args, :(write(out, neg?'-':'+'))) :
    ' ' in flags ? push!(blk.args, :(write(out, neg?'-':' '))) :
                    push!(blk.args, :(neg && write(out, '-')))
    # print zero padding
    if padding != nothing && !('-' in flags) && '0' in flags
        push!(blk.args, pad(width, padding, '0'))
    end
    # print digits
    push!(blk.args, :(write(out, DIGITS[1])))
    if precision > 0
        push!(blk.args, :(write(out, '.')))
        push!(blk.args, :(write(out, pointer(DIGITS)+1, $(ndigits-1))))
        if ndigits < precision+1
            n = precision+1-ndigits
            push!(blk.args, pad(n, n, '0'))
        end
    end
    for ch in expmark
        push!(blk.args, :(write(out, $ch)))
    end
    push!(blk.args, :(print_exp(out, exp)))
    # print space padding
    if padding != nothing && '-' in flags
        push!(blk.args, pad(width, padding, ' '))
    end
    # return arg, expr
    :(($x)::Real), ex
end

function gen_c(flags::ASCIIString, width::Int, precision::Int, c::Char)
    # print a character:
    #  [cC]: both the same for us (Unicode)
    #
    # flags:
    #  (0): pad left with zeros
    #  (-): left justify
    #
    @gensym x
    blk = Expr(:block, :($x = char($x)))
    if width > 1 && !('-' in flags)
        p = '0' in flags ? '0' : ' '
        push!(blk.args, pad(width-1, :($width-charwidth($x)), p))
    end
    push!(blk.args, :(write(out, $x)))
    if width > 1 && '-' in flags
        push!(blk.args, pad(width-1, :($width-charwidth($x)), ' '))
    end
    :(($x)::Integer), blk
end

function gen_s(flags::ASCIIString, width::Int, precision::Int, c::Char)
    # print a string:
    #  [sS]: both the same for us (Unicode)
    #
    # flags:
    #  (0): pad left with zeros
    #  (-): left justify
    #
    @gensym x
    blk = Expr(:block)
    if width > 0
        if !('#' in flags)
            push!(blk.args, :($x = string($x)))
        else
            push!(blk.args, :($x = repr($x)))
        end
        if !('-' in flags)
            push!(blk.args, pad(width, :($width-strwidth($x)), ' '))
        end
        push!(blk.args, :(write(out, $x)))
        if '-' in flags
            push!(blk.args, pad(width, :($width-strwidth($x)), ' '))
        end
    else
        if !('#' in flags)
            push!(blk.args, :(print(out, $x)))
        else
            push!(blk.args, :(show(out, $x)))
        end
    end
    :(($x)::Any), blk
end

# TODO: faster pointer printing.

function gen_p(flags::ASCIIString, width::Int, precision::Int, c::Char)
    # print pointer:
    #  [p]: the only option
    #
    @gensym x
    blk = Expr(:block)
    ptrwidth = WORD_SIZE>>2
    width -= ptrwidth+2
    if width > 0 && !('-' in flags)
        push!(blk.args, pad(width, width, ' '))
    end
    push!(blk.args, :(write(out, '0')))
    push!(blk.args, :(write(out, 'x')))
    push!(blk.args, :(write(out, bytestring(hex(unsigned($x), $ptrwidth)))))
    if width > 0 && '-' in flags
        push!(blk.args, pad(width, width, ' '))
    end
    :(($x)::Ptr), blk
end

function gen_g(flags::ASCIIString, width::Int, precision::Int, c::Char)
    error("printf \"%g\" format specifier not implemented")
end

### core unsigned integer decoding functions ###

macro handle_zero(ex)
    quote
        if $(esc(ex)) == 0
            DIGITS[1] = '0'
            return int32(1), int32(1), $(esc(:neg))
        end
    end
end

decode_oct(out, d, flags::ASCIIString, width::Int, precision::Int, c::Char) = (true, decode_oct(d))
decode_0ct(out, d, flags::ASCIIString, width::Int, precision::Int, c::Char) = (true, decode_0ct(d))
decode_dec(out, d, flags::ASCIIString, width::Int, precision::Int, c::Char) = (true, decode_dec(d))
decode_hex(out, d, flags::ASCIIString, width::Int, precision::Int, c::Char) = (true, decode_hex(d))
decode_HEX(out, d, flags::ASCIIString, width::Int, precision::Int, c::Char) = (true, decode_HEX(d))
fix_dec(out, d, flags::ASCIIString, width::Int, precision::Int, c::Char) = (true, fix_dec(d, precision))
ini_dec(out, d, ndigits::Int, flags::ASCIIString, width::Int, precision::Int, c::Char) = (true, ini_dec(d, ndigits))


# fallbacks for Real types without explicit decode_* implementation
decode_oct(d::Real) = decode_oct(integer(d))
decode_0ct(d::Real) = decode_0ct(integer(d))
decode_dec(d::Real) = decode_dec(integer(d))
decode_hex(d::Real) = decode_hex(integer(d))
decode_HEX(d::Real) = decode_HEX(integer(d))

handlenegative(d::Unsigned) = (false, d)
function handlenegative(d::Integer)
    if d < 0
        return true, unsigned(oftype(d,-d))
    else
        return false, unsigned(d)
    end
end

function decode_oct(d::Integer)
    neg, x = handlenegative(d)
    @handle_zero x
    pt = i = div((sizeof(x)<<3)-leading_zeros(x)+2,3)
    while i > 0
        DIGITS[i] = '0'+(x&0x7)
        x >>= 3
        i -= 1
    end
    return int32(pt), int32(pt), neg
end

function decode_0ct(d::Integer)
    neg, x = handlenegative(d)
    # doesn't need special handling for zero
    pt = i = div((sizeof(x)<<3)-leading_zeros(x)+5,3)
    while i > 0
        DIGITS[i] = '0'+(x&0x7)
        x >>= 3
        i -= 1
    end
    return int32(pt), int32(pt), neg
end

function decode_dec(d::Integer)
    neg, x = handlenegative(d)
    @handle_zero x
    pt = i = Base.ndigits0z(x)
    while i > 0
        DIGITS[i] = '0'+rem(x,10)
        x = div(x,10)
        i -= 1
    end
    return int32(pt), int32(pt), neg
end

function decode_hex(d::Integer, symbols::Array{Uint8,1})
    neg, x = handlenegative(d)
    @handle_zero x
    pt = i = (sizeof(x)<<1)-(leading_zeros(x)>>2)
    while i > 0
        DIGITS[i] = symbols[(x&0xf)+1]
        x >>= 4
        i -= 1
    end
    return int32(pt), int32(pt), neg
end

const hex_symbols = "0123456789abcdef".data
const HEX_symbols = "0123456789ABCDEF".data

decode_hex(x::Integer) = decode_hex(x,hex_symbols)
decode_HEX(x::Integer) = decode_hex(x,HEX_symbols)

function decode(b::Int, x::BigInt)
    neg = x.size < 0
    pt = Base.ndigits(x, abs(b))
    length(DIGITS) < pt+1 && resize!(DIGITS, pt+1)
    neg && (x.size = -x.size)
    ccall((:__gmpz_get_str, :libgmp), Ptr{Uint8},
          (Ptr{Uint8}, Cint, Ptr{BigInt}), DIGITS, b, &x)
    neg && (x.size = -x.size)
    return int32(pt), int32(pt), neg
end
decode_oct(x::BigInt) = decode(8, x)
decode_dec(x::BigInt) = decode(10, x)
decode_hex(x::BigInt) = decode(16, x)
decode_HEX(x::BigInt) = decode(-16, x)

function decode_0ct(x::BigInt)
    neg = x.size < 0
    DIGITS[1] = '0'
    if x.size == 0
        return int32(1), int32(1), neg
    end
    pt = Base.ndigits0z(x, 8) + 1
    length(DIGITS) < pt+1 && resize!(DIGITS, pt+1)
    neg && (x.size = -x.size)
    p = convert(Ptr{Uint8}, DIGITS) + 1
    ccall((:__gmpz_get_str, :libgmp), Ptr{Uint8},
          (Ptr{Uint8}, Cint, Ptr{BigInt}), p, 8, &x)
    neg && (x.size = -x.size)
    return neg, int32(pt), int32(pt)
end

### decoding functions directly used by printf generated code ###

# decode_*(x)=> fixed precision, to 0th place, filled out
# fix_*(x,n) => fixed precision, to nth place, not filled out
# ini_*(x,n) => n initial digits, filled out

# alternate versions:
#   *_0ct(x,n) => ensure that the first octal digits is zero
#   *_HEX(x,n) => use uppercase digits for hexadecimal

# - returns (len, point, neg)
# - implies len = point
#

function decode_dec(x::SmallFloatingPoint)
    if x == 0.0
        DIGITS[1] = '0'
        return (int32(1), int32(1), false)
    end
    @grisu_ccall x Grisu.FIXED 0
    if LEN[1] == 0
        DIGITS[1] = '0'
        return (int32(1), int32(1), false)
    else
        for i = LEN[1]+1:POINT[1]
            DIGITS[i] = '0'
        end
    end
    return LEN[1], POINT[1], NEG[1]
end
# TODO: implement decode_oct, decode_0ct, decode_hex, decode_HEX for SmallFloatingPoint

## fix decoding functions ##
#
# - returns (neg, point, len)
# - if len less than point, trailing zeros implied
#

# fallback for Real types without explicit fix_dec implementation
fix_dec(x::Real, n::Int) = fix_dec(float(x),n)

fix_dec(x::Integer, n::Int) = decode_dec(x)

function fix_dec(x::SmallFloatingPoint, n::Int)
    if n > BUFLEN-1; n = BUFLEN-1; end
    @grisu_ccall x Grisu.FIXED n
    if LEN[1] == 0
        DIGITS[1] = '0'
        return (int32(1), int32(1), NEG[1]) 
    end
    return LEN[1], POINT[1], NEG[1]
end

## ini decoding functions ##
#
# - returns (neg, point, len)
# - implies len = n (requested digits)
#

# fallback for Real types without explicit fix_dec implementation
ini_dec(x::Real, n::Int) = ini_dec(float(x),n)

function ini_dec(d::Integer, n::Int)
    neg, x = handlenegative(d)
    k = ndigits(x)
    if k <= n
        pt = k
        for i = k:-1:1
            DIGITS[i] = '0'+rem(x,10)
            x = div(x,10)
        end
        for i = k+1:n
            DIGITS[i] = '0'
        end
    else
        p = Base.powers_of_ten[k-n+1]
        r = rem(x,p)
        if r >= (p>>1)
            x += p
            if x >= Base.powers_of_ten[k+1]
                p *= 10
                k += 1
            end
        end
        pt = k
        x = div(x,p)
        for i = n:-1:1
            DIGITS[i] = '0'+rem(x,10)
            x = div(x,10)
        end
    end
    return n, pt, neg
end

function ini_dec(x::SmallFloatingPoint, n::Int)
    if x == 0.0
        ccall(:memset, Ptr{Void}, (Ptr{Void}, Cint, Csize_t), DIGITS, '0', n)
        return int32(1), int32(1), bool(signbit(x))
    else
        @grisu_ccall x Grisu.PRECISION n
    end
    return LEN[1], POINT[1], NEG[1]
end

function ini_dec(x::BigInt, n::Int)
    if x.size == 0
        ccall(:memset, Ptr{Void}, (Ptr{Void}, Cint, Csize_t), DIGITS, '0', n)
        return int32(1), int32(1), false
    end
    d = Base.ndigits0z(x)
    if d <= n
        info = decode_dec(x)
        d == n && return info
        p = convert(Ptr{Void}, DIGITS) + info[2]
        ccall(:memset, Ptr{Void}, (Ptr{Void}, Cint, Csize_t), p, '0', n - info[2])
        return info
    end
    return (n, d, decode_dec(iround(x/big(10)^(d-n)))[3])
end

#BigFloat
fix_dec(out, d::BigFloat, flags::ASCIIString, width::Int, precision::Int, c::Char) = bigfloat_printf(out, d, flags, width, precision, c)
ini_dec(out, d::BigFloat, ndigits::Int, flags::ASCIIString, width::Int, precision::Int, c::Char) = bigfloat_printf(out, d, flags, width, precision, c)
function bigfloat_printf(out, d, flags::ASCIIString, width::Int, precision::Int, c::Char)
    fmt_len = sizeof(flags)+4
    if width > 0
        fmt_len += ndigits(width)
    end
    if precision >= 0
        fmt_len += ndigits(precision)+1
    end
    fmt = IOBuffer(fmt_len)
    write(fmt, '%')
    write(fmt, flags)
    if width > 0
        print(fmt, width)
    end
    if precision == 0
        write(fmt, '.')
        write(fmt, '0')
    elseif precision > 0
        write(fmt, '.')
        print(fmt, precision)
    end
    write(fmt, 'R')
    write(fmt, c)
    write(fmt, uint8(0))
    printf_fmt = takebuf_array(fmt)
    @assert length(printf_fmt) == fmt_len
    lng = ccall((:mpfr_snprintf,:libmpfr), Int32, (Ptr{Uint8}, Culong, Ptr{Uint8}, Ptr{BigFloat}...), DIGITS, BUFLEN-1, printf_fmt, &d)
    lng > 0 || error("invalid printf formatting for BigFloat")
    write(out, pointer(DIGITS), lng)
    return (false, ())
end

### external printf interface ###

is_str_expr(ex) =
    isa(ex,Expr) && (ex.head == :string || (ex.head == :macrocall && isa(ex.args[1],Symbol) &&
    endswith(string(ex.args[1]),"str")))

function _printf(macroname, io, fmt, args)
    isa(fmt, String) || error("$macroname: format must be a plain static string (no interpolation or prefix)")
    sym_args, blk = gen(fmt)
    if length(sym_args) != length(args)
        error("$macroname: wrong number of arguments")
    end
    for i = length(args):-1:1
        var = sym_args[i].args[1]
        unshift!(blk.args, :($var = $(esc(args[i]))))
    end
    unshift!(blk.args, :(out = $io))
    blk
end

macro printf(args...)
    !isempty(args) || error("@printf: called with zero arguments")
    if isa(args[1], String) || is_str_expr(args[1])
        _printf("@printf", :STDOUT, args[1], args[2:end])
    else
        (length(args) >= 2 && (isa(args[2], String) || is_str_expr(args[2]))) ||
            error("@printf: first or second argument must be a format string")
        _printf("@printf", esc(args[1]), args[2], args[3:end])
    end
end

macro sprintf(args...)
    !isempty(args) || error("@sprintf: called with zero arguments")
    isa(args[1], String) || is_str_expr(args[1]) || 
        error("@sprintf: first argument must be a format string")
    blk = _printf("@sprintf", :(IOBuffer()), args[1], args[2:end])
    push!(blk.args, :(takebuf_string(out)))
    blk
end

end # module
