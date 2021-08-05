using Setfield

"""
    SimpleVarInfo{NT,T} <: AbstractVarInfo

A simple wrapper of the parameters with a `logp` field for
accumulation of the logdensity.

Currently only implemented for `NT <: NamedTuple`.

## Notes
The major differences between this and `TypedVarInfo` are:
1. `SimpleVarInfo` does not require linearization.
2. `SimpleVarInfo` can use more efficient bijectors.
3. `SimpleVarInfo` only supports evaluation.
"""
struct SimpleVarInfo{NT,T} <: AbstractVarInfo
    θ::NT
    logp::T
end

SimpleVarInfo{T}(θ) where {T<:Real} = SimpleVarInfo{typeof(θ),T}(θ, zero(T))
SimpleVarInfo(θ) = SimpleVarInfo{eltype(first(θ))}(θ)
SimpleVarInfo{T}() where {T<:Real} = SimpleVarInfo{T}(NamedTuple())
SimpleVarInfo() = SimpleVarInfo{Float64}()

# Constructor from `Model`.
SimpleVarInfo(model::Model, args...) = SimpleVarInfo{Float64}(model, args...)
function SimpleVarInfo{T}(model::Model, args...) where {T<:Real}
    _, svi = DynamicPPL.evaluate(model, SimpleVarInfo{T}(), args...)
    return svi
end

# Constructor from `VarInfo`.
function SimpleVarInfo(vi::TypedVarInfo, ::Type{D}=NamedTuple; kwargs...) where {D}
    return SimpleVarInfo{eltype(getlogp(vi))}(vi, D; kwargs...)
end
function SimpleVarInfo{T}(
    vi::VarInfo{<:NamedTuple{names}}, ::Type{D}
) where {T<:Real,names,D}
    values = values_as(vi, D)
    return SimpleVarInfo{T}(values)
end

getlogp(vi::SimpleVarInfo) = vi.logp
setlogp!!(vi::SimpleVarInfo, logp) = SimpleVarInfo(vi.θ, logp)
acclogp!!(vi::SimpleVarInfo, logp) = SimpleVarInfo(vi.θ, getlogp(vi) + logp)

function setlogp!!(vi::SimpleVarInfo{<:Any,<:Ref}, logp)
    vi.logp[] = logp
    return vi
end

function acclogp!!(vi::SimpleVarInfo{<:Any,<:Ref}, logp)
    vi.logp[] += logp
    return vi
end

function _getvalue(nt::NamedTuple, ::Val{sym}, inds=()) where {sym}
    # Use `getproperty` instead of `getfield`
    value = getproperty(nt, sym)
    return _getindex(value, inds)
end

# `NamedTuple`
function getval(vi::SimpleVarInfo, vn::VarName{sym}) where {sym}
    # If `sym` is found in `vi.θ` we assume it will be of correct
    # shape to support `getindex` for `vn.indexing`.
    # If `sym` is NOT found in `vi.θ`, we try `Symbol(vn)`.
    # This means that we support both the following cases:
    # 1. `x[1]` has been provided by the user and can be assumed to be
    #   of shape that allows us to call `_getvalue` on it.
    # 2. `x[1]` was not provided by the user, e.g. possibly obtained by
    #   sampling with a `SimpleVarInfo` which then produced the key `var"x[1]"`.
    return if haskey(vi.θ, sym)
        _getvalue(vi.θ, Val{sym}(), vn.indexing)
    else
        getproperty(vi.θ, Symbol(vn))
    end
end

# `Dict`
function getval(vi::SimpleVarInfo{<:Dict}, vn::VarName)
    return vi.θ[vn]
end

# `SimpleVarInfo` doesn't necessarily vectorize, so we can have arrays other than
# just `Vector`.
getval(vi::SimpleVarInfo, vns::AbstractArray{<:VarName}) = map(vn -> getval(vi, vn), vns)
# To disambiguiate.
getval(vi::SimpleVarInfo, vns::Vector{<:VarName}) = map(vn -> getval(vi, vn), vns)

haskey(vi::SimpleVarInfo, vn) = haskey(vi.θ, getsym(vn))

istrans(::SimpleVarInfo, vn::VarName) = false

getindex(vi::SimpleVarInfo, spl::SampleFromPrior) = vi.θ
getindex(vi::SimpleVarInfo, spl::SampleFromUniform) = vi.θ
# TODO: Should we do better?
getindex(vi::SimpleVarInfo, spl::Sampler) = vi.θ
getindex(vi::SimpleVarInfo, vn::VarName) = getval(vi, vn)
getindex(vi::SimpleVarInfo, vns::AbstractArray{<:VarName}) = getval(vi, vns)
# HACK: Need to disambiguiate.
getindex(vi::SimpleVarInfo, vns::Vector{<:VarName}) = getval(vi, vns)

# Necessary for `matchingvalue` to work properly.
function Base.eltype(
    vi::SimpleVarInfo{<:Any,T}, spl::Union{AbstractSampler,SampleFromPrior}
) where {T}
    return T
end

# `NamedTuple`
function push!!(
    vi::SimpleVarInfo{<:NamedTuple}, vn::VarName{sym,Tuple{}}, value, dist::Distribution, gidset::Set{Selector}
) where {sym}
    @set vi.θ = merge(vi.θ, NamedTuple{(sym,)}((value,)))
end
function push!!(
    vi::SimpleVarInfo{<:NamedTuple}, vn::VarName, value, dist::Distribution, gidset::Set{Selector}
) where {sym}
    @set vi.θ = merge(vi.θ, NamedTuple{(Symbol(vn),)}((value,)))
end

# `Dict`
function push!!(vi::SimpleVarInfo{<:Dict}, vn::VarName, r, dist::Distribution, gidset::Set{Selector})
    vi.θ[vn] = r
    return vi
end

# Context implementations
function tilde_assume!!(context, right, vn, inds, vi::SimpleVarInfo)
    value, logp, vi_new = tilde_assume(context, right, vn, inds, vi)
    return value, acclogp!!(vi_new, logp)
end

function assume(dist::Distribution, vn::VarName, vi::SimpleVarInfo)
    left = vi[vn]
    return left, Distributions.loglikelihood(dist, left), vi
end

function assume(
    rng::Random.AbstractRNG,
    sampler::SampleFromPrior,
    dist::Distribution,
    vn::VarName,
    vi::SimpleVarInfo,
)
    value = init(rng, dist, sampler)
    vi = push!!(vi, vn, value, dist, sampler)
    vi = settrans!!(vi, false, vn)
    return value, Distributions.loglikelihood(dist, value), vi
end

# function dot_tilde_assume!!(context, right, left, vn, inds, vi::SimpleVarInfo)
#     throw(MethodError(dot_tilde_assume!!, (context, right, left, vn, inds, vi)))
# end

function dot_tilde_assume!!(context, right, left, vn, inds, vi::SimpleVarInfo)
    value, logp, vi_new = dot_tilde_assume(context, right, left, vn, inds, vi)
    # Mutation of `value` no longer occurs in main body, so we do it here.
    left .= value
    return value, acclogp!!(vi_new, logp)
end

function dot_assume(
    dist::MultivariateDistribution,
    var::AbstractMatrix,
    vns::AbstractVector{<:VarName},
    vi::SimpleVarInfo,
)
    @assert length(dist) == size(var, 1)
    # NOTE: We cannot work with `var` here because we might have a model of the form
    #
    #     m = Vector{Float64}(undef, n)
    #     m .~ Normal()
    #
    # in which case `var` will have `undef` elements, even if `m` is present in `vi`.
    value = vi[vns]
    lp = sum(zip(vns, eachcol(value))) do vn, val
        return Distributions.logpdf(dist, val)
    end
    return value, lp, vi
end

function dot_assume(
    dists::Union{Distribution,AbstractArray{<:Distribution}},
    var::AbstractArray,
    vns::AbstractArray{<:VarName},
    vi::SimpleVarInfo{<:NamedTuple},
)
    # NOTE: We cannot work with `var` here because we might have a model of the form
    #
    #     m = Vector{Float64}(undef, n)
    #     m .~ Normal()
    #
    # in which case `var` will have `undef` elements, even if `m` is present in `vi`.
    value = vi[vns]
    lp = sum(Distributions.logpdf.(dists, value))
    return value, lp, vi
end

# HACK: Allows us to re-use the impleemntation of `dot_tilde`, etc. for literals.
increment_num_produce!(::SimpleVarInfo) = nothing
settrans!!(vi::SimpleVarInfo, trans::Bool, vn::VarName) = vi
