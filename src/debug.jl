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
            "https://github.com/fredrikekre/Runic.jl/issues/new."
    )
end

function macroexpand_assert(expr)
    msg = string(expr)
    return :($(esc(expr)) || throw(AssertionError($msg)))
end
