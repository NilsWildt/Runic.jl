# SPDX-License-Identifier: MIT

########################################################
# Node utilities extensions and JuliaSyntax extensions #
########################################################

# See JuliaSyntax/src/parse_stream.jl
function stringify_flags(node::Node)
    io = IOBuffer()
    if JuliaSyntax.has_flags(node, JuliaSyntax.TRIVIA_FLAG)
        write(io, "trivia,")
    end
    if JuliaSyntax.is_operator(kind(node))
        if JuliaSyntax.has_flags(node, JuliaSyntax.DOTOP_FLAG)
            write(io, "dotted,")
        end
        if JuliaSyntax.has_flags(node, JuliaSyntax.SUFFIXED_FLAG)
            write(io, "suffixed,")
        end
    end
    if kind(node) in KSet"call dotcall"
        if JuliaSyntax.has_flags(node, JuliaSyntax.PREFIX_CALL_FLAG)
            write(io, "prefix-call,")
        end
        if JuliaSyntax.has_flags(node, JuliaSyntax.INFIX_FLAG)
            write(io, "infix-op,")
        end
        if JuliaSyntax.has_flags(node, JuliaSyntax.PREFIX_OP_FLAG)
            write(io, "prefix-op,")
        end
        if JuliaSyntax.has_flags(node, JuliaSyntax.POSTFIX_OP_FLAG)
            write(io, "postfix-op,")
        end
    end
    if kind(node) in KSet"string cmdstring" &&
            JuliaSyntax.has_flags(node, JuliaSyntax.TRIPLE_STRING_FLAG)
        write(io, "triple,")
    end
    if kind(node) in KSet"string cmdstring Identifier" &&
            JuliaSyntax.has_flags(node, JuliaSyntax.RAW_STRING_FLAG)
        write(io, "raw,")
    end
    if kind(node) in KSet"tuple block macrocall" &&
            JuliaSyntax.has_flags(node, JuliaSyntax.PARENS_FLAG)
        write(io, "parens,")
    end
    if kind(node) === K"quote" && JuliaSyntax.has_flags(node, JuliaSyntax.COLON_QUOTE)
        write(io, "colon,")
    end
    if kind(node) === K"toplevel" && JuliaSyntax.has_flags(node, JuliaSyntax.TOPLEVEL_SEMICOLONS_FLAG)
        write(io, "semicolons,")
    end
    if kind(node) === K"struct" && JuliaSyntax.has_flags(node, JuliaSyntax.MUTABLE_FLAG)
        write(io, "mutable,")
    end
    if kind(node) === K"module" && JuliaSyntax.has_flags(node, JuliaSyntax.BARE_MODULE_FLAG)
        write(io, "baremodule,")
    end
    truncate(io, max(0, position(io) - 1)) # Remove trailing comma
    return String(take!(io))
end


# Node tags #

# This node is responsible for incrementing the indentation level
const TAG_INDENT = TagType(1) << 0
# This node is responsible for decrementing the indentation level
const TAG_DEDENT = TagType(1) << 1

function has_tag(node::Node, tag::TagType)
    return node.tags & tag != 0
end

function stringify_tags(node::Node)
    io = IOBuffer()
    if has_tag(node, TAG_INDENT)
        write(io, "indent,")
    end
    if has_tag(node, TAG_DEDENT)
        write(io, "dedent,")
    end
    truncate(io, max(0, position(io) - 1)) # Remove trailing comma
    return String(take!(io))
end

# Create a new node with the same head but new kids
function make_node(node::Node, kids′::Vector{Node}, tags = TagType(0))
    span′ = mapreduce(span, +, kids′; init = 0)
    return Node(head(node), span′, kids′, tags)
end

function first_leaf(node::Node)
    if is_leaf(node)
        return node
    else
        return first_leaf(first(verified_kids(node)))
    end
end

# Return number of non-whitespace kids, basically the length the equivalent
# (expr::Expr).args
function meta_nargs(node::Node)
    return is_leaf(node) ? 0 : count(!JuliaSyntax.is_whitespace, verified_kids(node))
end

function replace_first_leaf(node::Node, kid′::Node)
    if is_leaf(node)
        return kid′
    else
        kids′ = copy(verified_kids(node))
        kids′[1] = replace_first_leaf(kids′[1], kid′)
        @assert length(kids′) > 0
        return make_node(node, kids′)
    end
end

function last_leaf(node::Node)
    if is_leaf(node)
        return node
    else
        return last_leaf(last(verified_kids(node)))
    end
end

function is_assignment(node::Node)
    return JuliaSyntax.is_prec_assignment(node)
    # return !is_leaf(node) && JuliaSyntax.is_prec_assignment(node)
end

# Just like `JuliaSyntax.is_infix_op_call`, but also check that the node is K"call"
function is_infix_op_call(node::Node)
    return kind(node) === K"call" && JuliaSyntax.is_infix_op_call(node)
end

# Extract the operator of an infix op call node
function infix_op_call_op(node::Node)
    @assert is_infix_op_call(node)
    kids = verified_kids(node)
    first_operand_index = findfirst(!JuliaSyntax.is_whitespace, kids)
    op_index = findnext(JuliaSyntax.is_operator, kids, first_operand_index + 1)
    return kids[op_index]
end

# Comparison leaf or a dotted comparison leaf (.<)
function is_comparison_leaf(node::Node)
    if is_leaf(node) && JuliaSyntax.is_prec_comparison(node)
        return true
    elseif !is_leaf(node) && kind(node) === K"." &&
        meta_nargs(node) == 2 && is_comparison_leaf(verified_kids(node)[2])
        return true
    else
        return false
    end
end

function is_operator_leaf(node::Node)
    return is_leaf(node) && JuliaSyntax.is_operator(node)
end

function first_non_whitespace_kid(node::Node)
    @assert !is_leaf(node)
    kids = verified_kids(node)
    idx = findfirst(!JuliaSyntax.is_whitespace, kids)::Int
    return kids[idx]
end

##########################
# Utilities for IOBuffer #
##########################

# Replace bytes for a node at the current position in the IOBuffer. `size` is the current
# window for the node, i.e. the number of bytes until the next node starts. If `size` is
# smaller or larger than the length of `bytes` this method will shift the bytes for
# remaining nodes to the left or right. Return number of written bytes.
function replace_bytes!(io::IOBuffer, bytes::Union{String, AbstractVector{UInt8}}, size::Int)
    pos = position(io)
    nb = (bytes isa AbstractVector{UInt8} ? length(bytes) : sizeof(bytes))
    if nb == size
        nw = write(io, bytes)
        @assert nb == nw
    else
        backup = IOBuffer() # TODO: global const (with lock)?
        seek(io, pos + size)
        @assert position(io) == pos + size
        nb_written_to_backup = write(backup, io)
        seek(io, pos)
        @assert position(io) == pos
        nw = write(io, bytes)
        @assert nb == nw
        nb_read_from_backup = write(io, seekstart(backup))
        @assert nb_written_to_backup == nb_read_from_backup
        truncate(io, position(io))
    end
    seek(io, pos)
    @assert position(io) == pos
    return nb
end

replace_bytes!(io::IOBuffer, bytes::Union{String, AbstractVector{UInt8}}, size::Integer) =
    replace_bytes!(io, bytes, Int(size))
