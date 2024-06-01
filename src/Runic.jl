# SPDX-License-Identifier: MIT

module Runic

using JuliaSyntax:
    JuliaSyntax, @K_str, @KSet_str

# Julia compat for const struct fields
@eval macro $(Symbol("const"))(field)
    if VERSION >= v"1.8.0-DEV.1148"
        Expr(:const, esc(field))
    else
        return esc(field)
    end
end

# Debug and assert utilities
include("debug.jl")

########
# Node #
########

# This is essentially just a re-packed `JuliaSyntax.GreenNode`.
struct Node
    # The next three fields directly match JuliaSyntax.GreenNode. We can not store a
    # GreenNode directly because the type of the children vector should be `Vector{Node}`
    # and not `Vector{GreenNode}`.
    head::JuliaSyntax.SyntaxHead
    span::UInt32
    kids::Union{Tuple{}, Vector{Node}}
end

# Re-package a GreenNode as a Node
function Node(node::JuliaSyntax.GreenNode)
    return Node(
        JuliaSyntax.head(node), JuliaSyntax.span(node),
        map(Node, JuliaSyntax.children(node)),
    )
end

# Defining these allow using many duck-typed methods in JuliaSyntax directly without having
# to re-package a Node as a GreenNode.
JuliaSyntax.head(node::Node) = head(node)
JuliaSyntax.span(node::Node) = span(node)

# Matching JuliaSyntax.(head|span|flags|kind)
head(node::Node) = node.head
span(node::Node) = node.span
flags(node::Node) = JuliaSyntax.flags(node)
kind(node::Node) = JuliaSyntax.kind(node)

# Inverse of JuliaSyntax.haschildren
function is_leaf(node::Node)
    return node.kids === ()
end

# This function must only be be called after verifying that the node is not a leaf. We can
# then type-assert the return value to narrow it down from `Union{Tuple{}, Vector{Node}}` to
# `Vector{Node}`.
function verified_kids(node::Node)
    @assert !is_leaf(node)
    return node.kids::Vector{Node}
end

# Node utilities and JuliaSyntax extensions
include("chisels.jl")

# Return the result of expr if it doesn't evaluate to `nothing`
macro return_something(expr)
    return :(let node = $(esc(expr))
        node === nothing || return node
    end)
end

#######################################################
# Main drivers for traversing and formatting the tree #
#######################################################

mutable struct Context
    # Input
    @const src_str::String
    @const src_tree::Node
    @const src_io::IOBuffer
    # Output
    @const fmt_io::IOBuffer
    fmt_tree::Union{Node, Nothing}
    # User settings
    quiet::Bool
    verbose::Bool
    assert::Bool
    debug::Bool
    check::Bool
    diff::Bool
    # Current state
    # node::Union{Node, Nothing}
    prev_sibling::Union{Node, Nothing}
    next_sibling::Union{Node, Nothing}
    # parent::Union{Node, Nothing}
end

function Context(
        src_str; assert::Bool = true, debug::Bool = false, verbose::Bool = debug,
        diff::Bool = false, check::Bool = false, quiet::Bool = false,
    )
    src_io = IOBuffer(src_str)
    src_tree = Node(
        JuliaSyntax.parseall(JuliaSyntax.GreenNode, src_str; ignore_warnings = true),
    )
    fmt_io = IOBuffer()
    fmt_tree = nothing
    # Debug mode enforces verbose and assert
    verbose = debug ? true : verbose
    assert = debug ? true : assert
    return Context(
        src_str, src_tree, src_io, fmt_io, fmt_tree,
        quiet, verbose, assert, debug, check, diff, nothing, nothing,
    )
end

function next_sibling_kind(ctx::Context)::Union{JuliaSyntax.Kind, Nothing}
    next = ctx.next_sibling
    return next === nothing ? nothing : JuliaSyntax.kind(next)
end

# Read the bytes of the current node from the output io
function read_bytes(ctx, node)
    pos = position(ctx.fmt_io)
    bytes = read(ctx.fmt_io, span(node))
    @assert length(bytes) == span(node)
    seek(ctx.fmt_io, pos)
    @assert position(ctx.fmt_io) == pos
    return bytes
end

function accept_node!(ctx::Context, node::Node)
    # Accept the string representation of the current node by advancing the
    # output IO to the start of the next node
    pos = position(ctx.fmt_io) + span(node)
    seek(ctx.fmt_io, pos)
    return
end

function replace_bytes!(ctx::Context, bytes::Union{String, AbstractVector{UInt8}}, sz::Integer)
    return replace_bytes!(ctx.fmt_io, bytes, Int(sz))
end

struct NullNode end
const nullnode = NullNode()

function format_node_with_kids!(ctx::Context, node::Node)
    # If the node doesn't have kids there is nothing to do here
    if is_leaf(node)
        return nothing
    end

    # Keep track of the siblings on this stack
    prev_sibling = ctx.prev_sibling
    next_sibling = ctx.next_sibling
    ctx.prev_sibling = nothing
    ctx.next_sibling = nothing

    # The new node parts. `kids′` aliases `kids` and only copied below if any of the
    # nodes change ("copy-on-write").
    kids = verified_kids(node)
    kids′ = kids
    any_kid_changed = false

    # Loop over all the kids
    for (i, kid) in pairs(kids)
        # Set the siblings: previous from kids′, next from kids
        ctx.prev_sibling = get(kids′, i - 1, nothing)
        ctx.next_sibling = get(kids, i + 1, nothing)
        kid′ = kid
        this_kid_changed = false
        itr = 0
        # Loop until this node reaches a steady state and is accepted
        while true
            # Keep track of the stream position and reset it below if the node is changed
            fmt_pos = position(ctx.fmt_io)
            # Format the kid
            kid′′ = format_node!(ctx, kid′)
            if kid′′ === nullnode
                # This node should be deleted from the tree
                # TODO: When this is fixed the sibling setting above needs to be modified to
                # handle this too
                this_kid_changed = true
                error("TODO: handle removed kids")
            elseif kid′′ === nothing
                # The node was accepted, continue to next sibling
                @assert position(ctx.fmt_io) == fmt_pos + span(kid′)
                break
            else
                # The node should be replaced with the new one. Reset the stream and try
                # again until it is accepted.
                @assert kid′′ isa Node
                this_kid_changed = true
                seek(ctx.fmt_io, fmt_pos)
                kid′ = kid′′
            end
            if (itr += 1) == 1000
                error("infinite loop?")
            end
        end
        any_kid_changed |= this_kid_changed
        if any_kid_changed
            # De-alias the kids if not already done
            if kids′ === kids
                kids′ = eltype(kids)[kids[j] for j in 1:(i - 1)]
            end
            push!(kids′, kid′)
        end
    end
    # Reset the siblings
    ctx.prev_sibling = prev_sibling
    ctx.next_sibling = next_sibling
    # Return a new node if any of the kids changed
    if any_kid_changed
        return make_node(node, kids′)
    else
        return nothing
    end
end

"""
    format_node!(ctx::Context, node::JuliaSyntax.GreenNode)

Format a node. Return values:
 - `nothing::Nothing`: The node is accepted as is
 - `nullnode::NullNode`: The node should be deleted from the tree
 - `node::JuliaSyntax.GreenNode`: The node should be replaced with the new node
"""
function format_node!(ctx::Context, node::Node)::Union{Node, Nothing, NullNode}
    node_kind = kind(node)

    # Go through the runestone and apply transformations.
    @return_something trim_trailing_whitespace(ctx, node)
    @return_something format_hex_literals(ctx, node)
    @return_something format_oct_literals(ctx, node)
    @return_something format_float_literals(ctx, node)
    @return_something spaces_around_operators(ctx, node)
    @return_something spaces_around_assignments(ctx, node)
    @return_something no_spaces_around_colon_etc(ctx, node)
    @return_something for_loop_use_in(ctx, node)

    # If the node is unchanged at this point, just keep going.

    # Nodes that always recurse!
    if (
        node_kind === K"block" ||
        node_kind === K"braces" ||
        node_kind === K"bracescat" || # {a; b}
        node_kind === K"call" ||
        node_kind === K"cartesian_iterator" ||
        node_kind === K"char" ||
        node_kind === K"cmdstring" ||
        node_kind === K"comparison" ||
        node_kind === K"comprehension" ||
        node_kind === K"core_@cmd" ||
        node_kind === K"curly" ||
        node_kind === K"dotcall" ||
        node_kind === K"filter" ||
        node_kind === K"generator" ||
        node_kind === K"hcat" ||
        node_kind === K"importpath" ||
        node_kind === K"inert" ||
        node_kind === K"juxtapose" ||
        node_kind === K"macrocall" ||
        node_kind === K"ncat" ||
        node_kind === K"nrow" ||
        node_kind === K"parens" ||
        node_kind === K"ref" ||
        node_kind === K"row" ||
        node_kind === K"string" ||
        node_kind === K"toplevel" ||
        node_kind === K"typed_comprehension" ||
        node_kind === K"typed_hcat" ||
        node_kind === K"typed_ncat" ||
        node_kind === K"typed_vcat" ||
        node_kind === K"vcat" ||
        node_kind === K"vect"
    )
        @assert !JuliaSyntax.is_trivia(node)
        node′ = format_node_with_kids!(ctx, node)
        @assert node′ !== nullnode
        return node′

        # Nodes that recurse! if not trivia
        elseif !JuliaSyntax.is_trivia(node) && (
           node_kind === K"abstract" ||
           node_kind === K"as" ||
           node_kind === K"break" ||
           node_kind === K"catch" ||
           node_kind === K"const" ||
           node_kind === K"continue" ||
           node_kind === K"do" ||
           node_kind === K"doc" ||
           node_kind === K"elseif" ||
           node_kind === K"export" ||
           node_kind === K"finally" ||
           node_kind === K"for" ||
           node_kind === K"function" ||
           node_kind === K"global" ||
           node_kind === K"if" ||
           node_kind === K"import" ||
           node_kind === K"let" ||
           node_kind === K"local" ||
           node_kind === K"macro" ||
           node_kind === K"module" ||
           node_kind === K"outer" ||
           node_kind === K"parameters" ||
           node_kind === K"primitive" ||
           node_kind === K"quote" ||
           node_kind === K"return" ||
           node_kind === K"struct" ||
           node_kind === K"try" ||
           node_kind === K"tuple" ||
           node_kind === K"using" ||
           node_kind === K"var" ||
           node_kind === K"where" ||
           node_kind === K"while"
        )
        node′ = format_node_with_kids!(ctx, node)
        @assert node′ !== nullnode
        return node′

    # Nodes that should recurse if they have kids (all??)
    elseif !is_leaf(node) && (
        JuliaSyntax.is_operator(node) ||
        node_kind === K"else" # try-(catch|finally)-else
    )
        node′ = format_node_with_kids!(ctx, node)
        @assert node′ !== nullnode
        return node′

    # Whitespace and comments emitted verbatim for now
    elseif node_kind === K"Whitespace" ||
           node_kind === K"NewlineWs" ||
           node_kind === K"Comment"
        accept_node!(ctx, node)
        return nothing

    # Nodes that always emit like the source code
    elseif (
        node_kind === K"(" ||
        node_kind === K")" ||
        node_kind === K"," ||
        node_kind === K"::" ||
        node_kind === K";" ||
        node_kind === K"<:" ||
        node_kind === K"@" ||
        node_kind === K"BinInt" ||
        node_kind === K"Char" ||
        node_kind === K"CmdMacroName" ||
        node_kind === K"CmdString" ||
        node_kind === K"Float" ||
        node_kind === K"Float32" ||
        node_kind === K"HexInt" ||
        node_kind === K"Identifier" ||
        node_kind === K"Integer" ||
        node_kind === K"MacroName" ||
        node_kind === K"OctInt" ||
        node_kind === K"String" ||
        node_kind === K"StringMacroName" ||
        node_kind === K"false" ||
        node_kind === K"true" ||
        node_kind === K"type" ||
        JuliaSyntax.is_operator(node) ||
        JuliaSyntax.is_trivia(node) && (
            node_kind === K"$" ||
            node_kind === K"=" ||
            node_kind === K"[" ||
            node_kind === K"\"" ||
            node_kind === K"\"\"\"" ||
            node_kind === K"]" ||
            node_kind === K"`" ||
            node_kind === K"```" ||
            node_kind === K"abstract" ||
            node_kind === K"as" ||
            node_kind === K"baremodule" ||
            node_kind === K"begin" ||
            node_kind === K"break" ||
            node_kind === K"catch" ||
            node_kind === K"const" ||
            node_kind === K"continue" ||
            node_kind === K"do" ||
            node_kind === K"else" ||
            node_kind === K"elseif" ||
            node_kind === K"end" ||
            node_kind === K"export" ||
            node_kind === K"finally" ||
            node_kind === K"for" ||
            node_kind === K"function" ||
            node_kind === K"global" ||
            node_kind === K"if" ||
            node_kind === K"import" ||
            node_kind === K"in" ||
            node_kind === K"let" ||
            node_kind === K"local" ||
            node_kind === K"macro" ||
            node_kind === K"module" ||
            node_kind === K"mutable" ||
            node_kind === K"outer" ||
            node_kind === K"primitive" ||
            node_kind === K"quote" ||
            node_kind === K"return" ||
            node_kind === K"struct" ||
            node_kind === K"try" ||
            node_kind === K"using" ||
            node_kind === K"var" ||
            node_kind === K"while" ||
            node_kind === K"{" ||
            node_kind === K"}"
        )
    )
        accept_node!(ctx, node)
        return nothing
    else
        msg = "unhandled node of type $(node_kind), current text:\n" * String(take!(ctx.fmt_io))
        throw(ErrorException(msg))
    end
end

# Entrypoint
function format_tree!(ctx::Context)
    root = ctx.src_tree
    # Write the root node to the output IO so that the formatter can read it if needed
    src_pos = position(ctx.src_io)
    @assert src_pos == 0
    fmt_pos = position(ctx.fmt_io)
    @assert fmt_pos == 0
    nb = write(ctx.fmt_io, read(ctx.src_io, span(root)))
    @assert nb == span(root)
    # Reset IOs so that the offsets are correct
    seek(ctx.src_io, src_pos)
    seek(ctx.fmt_io, fmt_pos)
    # Set the root to the current node
    root′ = root
    itr = 0
    while true
        # Format the node.
        root′′ = format_node!(ctx, root′)
        if root′′ === nullnode
            # This signals that the node should be deleted, but that doesn't make sense for
            # the root node so error instead
            error("root node deleted")
        elseif root′′ === nothing
            # root′ = root′′
            @assert position(ctx.fmt_io) == fmt_pos + span(root′)
            break
        else
            @assert root′′ isa Node
            # The node was changed, reset the output stream and try again
            seek(ctx.fmt_io, fmt_pos)
            root′ = root′′
        end
        # The root node must only change once.
        if (itr += 1) == 2
            error("root node modified more than once")
        end
    end
    # Truncate the output at the root span
    truncate(ctx.fmt_io, span(root′))
    # Set the final tree
    ctx.fmt_tree = root′
    return nothing
end

"""
    format_string(str::AbstractString) -> String

Format a string.
"""
function format_string(str::AbstractString)
    ctx = Context(str)
    format_tree!(ctx)
    return String(take!(ctx.fmt_io))
end

"""
    format_file(inputfile::AbstractString, outputfile::AbstractString; inplace::Bool=false)

Format a file.
"""
function format_file(inputfile::AbstractString, outputfile::AbstractString = inputfile; inplace::Bool = false)
    # Argument handling
    inputfile = normpath(abspath(inputfile))
    outputfile = normpath(abspath(outputfile))
    str = read(inputfile, String)
    if !inplace && (outputfile == inputfile || (isfile(outputfile) && samefile(inputfile, outputfile)))
        error("input and output must not be the same when `inplace = false`")
    end
    # Format it
    ctx = Context(str)
    format_tree!(ctx)
    # Write the output but skip if it text didn't change
    changed = ctx.fmt_tree !== nothing
    if changed || !inplace
        write(outputfile, take!(ctx.fmt_io))
    end
    return
end

include("runestone.jl")
include("main.jl")

end # module
