# SPDX-License-Identifier: MIT

##############
# Debug info #
##############

# @lock is defined but not exported in older Julia versions
if VERSION < v"1.7.0"
    using Base: @lock
end

# Code derived from ToggleableAsserts.jl kept in a separate file
include("ToggleableAsserts.jl")

abstract type RunicException <: Exception end

struct AssertionError <: RunicException
    msg::String
end

function Base.showerror(io::IO, err::AssertionError)
    print(
        io,
        "Runic.AssertionError: `", err.msg, "`. This is unexpected, " *
        "please file an issue with a reproducible example at " *
        "https://github.com/fredrikekre/Runic.jl/issues/new.",
    )
end

function macroexpand_assert(expr)
    msg = string(expr)
    return :($(esc(expr)) || throw(AssertionError($msg)))
end


##########################
# JuliaSyntax extensions #
##########################

# Create a new node with the same head but new children
function make_node(node::JuliaSyntax.GreenNode, children′::AbstractVector{<:JuliaSyntax.GreenNode})
    span′ = mapreduce(JuliaSyntax.span, +, children′; init = 0)
    return JuliaSyntax.GreenNode(JuliaSyntax.head(node), span′, children′)
end

function is_leaf(node::JuliaSyntax.GreenNode)
    return !JuliaSyntax.haschildren(node)
end

function first_leaf(node::JuliaSyntax.GreenNode)
    if is_leaf(node)
        return node
    else
        return first_leaf(first(verified_children(node)))
    end
end

# Return number of non-whitespace children
function n_children(node::JuliaSyntax.GreenNode)
    return is_leaf(node) ? 0 : count(!JuliaSyntax.is_whitespace, verified_children(node))
end

# This function exist so that we can type-assert the return value to narrow it down from
# `Union{Tuple{}, Vector{JuliaSyntax.GreenNode}}` to `Vector{JuliaSyntax.GreenNode}`. Must
# only be called after verifying that the node has children.
function verified_children(node::JuliaSyntax.GreenNode)
    @assert JuliaSyntax.haschildren(node)
    return JuliaSyntax.children(node)::AbstractVector
end

function replace_first_leaf(node::JuliaSyntax.GreenNode, child′::JuliaSyntax.GreenNode)
    if is_leaf(node)
        return child′
    else
        children′ = copy(verified_children(node))
        children′[1] = replace_first_leaf(children′[1], child′)
        @assert length(children′) > 0
        return make_node(node, children′)
    end
end

function last_leaf(node::JuliaSyntax.GreenNode)
    if is_leaf(node)
        return node
    else
        return last_leaf(last(verified_children(node)))
    end
end

function is_assignment(node::JuliaSyntax.GreenNode)
    return JuliaSyntax.is_prec_assignment(node)
    return !is_leaf(node) && JuliaSyntax.is_prec_assignment(node)
end

# Just like `JuliaSyntax.is_infix_op_call`, but also check that the node is K"call"
function is_infix_op_call(node::JuliaSyntax.GreenNode)
    return JuliaSyntax.kind(node) === K"call" &&
        JuliaSyntax.is_infix_op_call(node)
end

function infix_op_call_op(node::JuliaSyntax.GreenNode)
    @assert is_infix_op_call(node)
    children = verified_children(node)
    first_operand_index = findfirst(!JuliaSyntax.is_whitespace, children)
    op_index = findnext(JuliaSyntax.is_operator, children, first_operand_index + 1)
    return children[op_index]
end

# Comparison leaf or a dotted comparison leaf (.<)
function is_comparison_leaf(node::JuliaSyntax.GreenNode)
    if is_leaf(node) && JuliaSyntax.is_prec_comparison(node)
        return true
    elseif !is_leaf(node) && JuliaSyntax.kind(node) === K"." &&
        n_children(node) == 2 && is_comparison_leaf(verified_children(node)[2])
        return true
    else
        return false
    end
end

function is_operator_leaf(node::JuliaSyntax.GreenNode)
    return is_leaf(node) && JuliaSyntax.is_operator(node)
end

function first_non_whitespace_child(node::JuliaSyntax.GreenNode)
    @assert !is_leaf(node)
    children = verified_children(node)
    idx = findfirst(!JuliaSyntax.is_whitespace, children)::Int
    return children[idx]
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
