"""
    SimpleVarInfo{NT,T} <: AbstractVarInfo

A simple wrapper of the parameters with a `logp` field for
accumulation of the logdensity.

Currently only implemented for `NT<:NamedTuple` and `NT<:Dict`.

# Notes
The major differences between this and `TypedVarInfo` are:
1. `SimpleVarInfo` does not require linearization.
2. `SimpleVarInfo` can use more efficient bijectors.
3. `SimpleVarInfo` is only type-stable if `NT<:NamedTuple` and either
   a) no indexing is used in tilde-statements, or
   b) the values have been specified with the correct shapes.

# Examples
## General usage
```jldoctest; setup=:(using Distributions)
julia> using StableRNGs

julia> @model function demo()
           m ~ Normal()
           x = Vector{Float64}(undef, 2)
           for i in eachindex(x)
               x[i] ~ Normal()
           end
           return x
       end
demo (generic function with 2 methods)

julia> m = demo();

julia> rng = StableRNG(42);

julia> ### Sampling ###
       ctx = SamplingContext(rng, SampleFromPrior(), DefaultContext());

julia> # In the `NamedTuple` version we need to provide the place-holder values for
       # the variables which are using "containers", e.g. `Array`.
       # In this case, this means that we need to specify `x` but not `m`.
       _, vi = DynamicPPL.evaluate!!(m, SimpleVarInfo((x = ones(2), )), ctx);

julia> # (✓) Vroom, vroom! FAST!!!
       vi[@varname(x[1])]
0.4471218424633827

julia> # We can also access arbitrary varnames pointing to `x`, e.g.
       vi[@varname(x)]
2-element Vector{Float64}:
 0.4471218424633827
 1.3736306979834252

julia> vi[@varname(x[1:2])]
2-element Vector{Float64}:
 0.4471218424633827
 1.3736306979834252

julia> # (×) If we don't provide the container...
       _, vi = DynamicPPL.evaluate!!(m, SimpleVarInfo(), ctx); vi
ERROR: type NamedTuple has no field x
[...]

julia> # If one does not know the varnames, we can use a `Dict` instead.
       _, vi = DynamicPPL.evaluate!!(m, SimpleVarInfo{Float64}(Dict()), ctx);

julia> # (✓) Sort of fast, but only possible at runtime.
       vi[@varname(x[1])]
-1.019202452456547

julia> # In addtion, we can only access varnames as they appear in the model!
       vi[@varname(x)]
ERROR: KeyError: key x not found
[...]

julia> vi[@varname(x[1:2])]
ERROR: KeyError: key x[1:2] not found
[...]
```

## Indexing
Using `NamedTuple` as underlying storage.

```jldoctest
julia> svi_nt = SimpleVarInfo((m = (a = [1.0], ), ));

julia> svi_nt[@varname(m)]
(a = [1.0],)

julia> svi_nt[@varname(m.a)]
1-element Vector{Float64}:
 1.0

julia> svi_nt[@varname(m.a[1])]
1.0

julia> svi_nt[@varname(m.a[2])]
ERROR: BoundsError: attempt to access 1-element Vector{Float64} at index [2]
[...]

julia> svi_nt[@varname(m.b)]
ERROR: type NamedTuple has no field b
[...]
```

Using `Dict` as underlying storage.
```jldoctest
julia> svi_dict = SimpleVarInfo(Dict(@varname(m) => (a = [1.0], )));

julia> svi_dict[@varname(m)]
(a = [1.0],)

julia> svi_dict[@varname(m.a)]
1-element Vector{Float64}:
 1.0

julia> svi_dict[@varname(m.a[1])]
1.0

julia> svi_dict[@varname(m.a[2])]
ERROR: BoundsError: attempt to access 1-element Vector{Float64} at index [2]
[...]

julia> svi_dict[@varname(m.b)]
ERROR: type NamedTuple has no field b
[...]
```
"""
struct SimpleVarInfo{NT,T} <: AbstractVarInfo
    values::NT
    logp::T
end

SimpleVarInfo{T}(θ) where {T<:Real} = SimpleVarInfo{typeof(θ),T}(θ, zero(T))
SimpleVarInfo{T}(; kwargs...) where {T<:Real} = SimpleVarInfo{T}(NamedTuple(kwargs))
SimpleVarInfo(; kwargs...) = SimpleVarInfo{Float64}(NamedTuple(kwargs))
SimpleVarInfo(θ) = SimpleVarInfo{Float64}(θ)

# Constructor from `Model`.
SimpleVarInfo(model::Model, args...) = SimpleVarInfo{Float64}(model, args...)
function SimpleVarInfo{T}(model::Model, args...) where {T<:Real}
    return last(evaluate!!(model, SimpleVarInfo{T}(), args...))
end

# Constructor from `VarInfo`.
function SimpleVarInfo(vi::TypedVarInfo, ::Type{D}=NamedTuple; kwargs...) where {D}
    return SimpleVarInfo{eltype(getlogp(vi))}(vi, D; kwargs...)
end
function SimpleVarInfo{T}(
    vi::VarInfo{<:NamedTuple{names}}, ::Type{D}
) where {T<:Real,names,D}
    values = values_as(vi, D)
    return SimpleVarInfo(values, convert(T, getlogp(vi)))
end

function BangBang.empty!!(vi::SimpleVarInfo)
    Setfield.@set resetlogp!!(vi).values = empty!!(vi.values)
end

getlogp(vi::SimpleVarInfo) = vi.logp
setlogp!!(vi::SimpleVarInfo, logp) = SimpleVarInfo(vi.values, logp)
acclogp!!(vi::SimpleVarInfo, logp) = SimpleVarInfo(vi.values, getlogp(vi) + logp)

"""
    keys(vi::SimpleVarInfo)

Return an iterator of keys present in `vi`.
"""
Base.keys(vi::SimpleVarInfo) = keys(vi.values)

function setlogp!!(vi::SimpleVarInfo{<:Any,<:Ref}, logp)
    vi.logp[] = logp
    return vi
end

function acclogp!!(vi::SimpleVarInfo{<:Any,<:Ref}, logp)
    vi.logp[] += logp
    return vi
end

function Base.show(io::IO, ::MIME"text/plain", svi::SimpleVarInfo)
    return print(io, "SimpleVarInfo(", svi.values, ", ", svi.logp, ")")
end

# `NamedTuple`
Base.getindex(vi::SimpleVarInfo, vn::VarName) = get(vi.values, vn)

# `Dict`
function Base.getindex(vi::SimpleVarInfo{<:AbstractDict}, vn::VarName)
    if haskey(vi.values, vn)
        return vi.values[vn]
    end

    # Split the lens into the key / `parent` and the extraction lens / `child`.
    parent, child, issuccess = splitlens(getlens(vn)) do lens
        l = lens === nothing ? Setfield.IdentityLens() : lens
        haskey(vi.values, VarName(vn, l))
    end
    # When combined with `VarInfo`, `nothing` is equivalent to `IdentityLens`.
    keylens = parent === nothing ? Setfield.IdentityLens() : parent

    # If we found a valid split, then we can extract the value.
    if !issuccess
        # At this point we just throw an error since the key could not be found.
        throw(KeyError(vn))
    end

    # TODO: Should we also check that we `canview` the extracted `value`
    # rather than just let it fail upon `get` call?
    value = vi.values[VarName(vn, keylens)]
    return get(value, child)
end

# `SimpleVarInfo` doesn't necessarily vectorize, so we can have arrays other than
# just `Vector`.
function Base.getindex(vi::SimpleVarInfo, vns::AbstractArray{<:VarName})
    return map(Base.Fix1(getindex, vi), vns)
end
# HACK: Needed to disambiguiate.
Base.getindex(vi::SimpleVarInfo, vns::Vector{<:VarName}) = map(Base.Fix1(getindex, vi), vns)

Base.getindex(vi::SimpleVarInfo, spl::SampleFromPrior) = vi.values
Base.getindex(vi::SimpleVarInfo, spl::SampleFromUniform) = vi.values
# TODO: Should we do better?
Base.getindex(vi::SimpleVarInfo, spl::Sampler) = vi.values

Base.haskey(vi::SimpleVarInfo, vn::VarName) = _haskey(vi.values, vn)
function _haskey(nt::NamedTuple, vn::VarName)
    # LHS: Ensure that `nt` indeed has the property we want.
    # RHS: Ensure that the lens can view into `nt`.
    sym = getsym(vn)
    return haskey(nt, sym) && canview(getlens(vn), getproperty(nt, sym))
end

# For `dictlike` we need to check wether `vn` is "immediately" present, or
# if some ancestor of `vn` is present in `dictlike`.
function _haskey(dict::AbstractDict, vn::VarName)
    # First we check if `vn` is present as is.
    haskey(dict, vn) && return true

    # If `vn` is not present, we check any parent-varnames by attempting
    # to split the lens into the key / `parent` and the extraction lens / `child`.
    # If `issuccess` is `true`, we found such a split, and hence `vn` is present.
    parent, child, issuccess = splitlens(getlens(vn)) do lens
        l = lens === nothing ? Setfield.IdentityLens() : lens
        haskey(dict, VarName(vn, l))
    end
    # When combined with `VarInfo`, `nothing` is equivalent to `IdentityLens`.
    keylens = parent === nothing ? Setfield.IdentityLens() : parent

    # Return early if no such split could be found.
    issuccess || return false

    # At this point we just need to check that we `canview` the value.
    value = dict[VarName(vn, keylens)]

    return canview(child, value)
end

function BangBang.setindex!!(vi::SimpleVarInfo, val, vn::VarName)
    # For `NamedTuple` we treat the symbol in `vn` as the _property_ to set.
    return SimpleVarInfo(set!!(vi.values, vn, val), vi.logp)
end

# TODO: Specialize to handle certain cases, e.g. a collection of `VarName` with
# same symbol and same type of, say, `IndexLens`, for improved `.~` performance.
function BangBang.setindex!!(vi::SimpleVarInfo, vals, vns::AbstractVector{<:VarName})
    for (vn, val) in zip(vns, vals)
        vi = BangBang.setindex!!(vi, val, vn)
    end
    return vi
end

function BangBang.setindex!!(vi::SimpleVarInfo{<:AbstractDict}, val, vn::VarName)
    # For dictlike objects, we treat the entire `vn` as a _key_ to set.
    dict = values_as(vi)
    # Attempt to split into `parent` and `child` lenses.
    parent, child, issuccess = splitlens(getlens(vn)) do lens
        l = lens === nothing ? Setfield.IdentityLens() : lens
        haskey(dict, VarName(vn, l))
    end
    # When combined with `VarInfo`, `nothing` is equivalent to `IdentityLens`.
    keylens = parent === nothing ? Setfield.IdentityLens() : parent

    dict_new = if !issuccess
        # Split doesn't exist ⟹ we're working with a new key.
        BangBang.setindex!!(dict, val, vn)
    else
        # Split exists ⟹ trying to set an existing key.
        vn_key = VarName(vn, keylens)
        BangBang.setindex!!(dict, set!!(dict[vn_key], child, val), vn_key)
    end
    return SimpleVarInfo(dict_new, vi.logp)
end

# `NamedTuple`
function BangBang.push!!(
    vi::SimpleVarInfo{<:NamedTuple},
    vn::VarName{sym,Setfield.IdentityLens},
    value,
    dist::Distribution,
    gidset::Set{Selector},
) where {sym}
    return Setfield.@set vi.values = merge(vi.values, NamedTuple{(sym,)}((value,)))
end
function BangBang.push!!(
    vi::SimpleVarInfo{<:NamedTuple},
    vn::VarName{sym},
    value,
    dist::Distribution,
    gidset::Set{Selector},
) where {sym}
    return Setfield.@set vi.values = set!!(vi.values, vn, value)
end

# `Dict`
function BangBang.push!!(
    vi::SimpleVarInfo{<:AbstractDict},
    vn::VarName,
    r,
    dist::Distribution,
    gidset::Set{Selector},
)
    vi.values[vn] = r
    return vi
end

const SimpleOrThreadSafeSimple{T,V} = Union{
    SimpleVarInfo{T,V},ThreadSafeVarInfo{<:SimpleVarInfo{T,V}}
}

# Necessary for `matchingvalue` to work properly.
function Base.eltype(
    vi::SimpleOrThreadSafeSimple{<:Any,V}, spl::Union{AbstractSampler,SampleFromPrior}
) where {V}
    return V
end

# Context implementations
function assume(dist::Distribution, vn::VarName, vi::SimpleOrThreadSafeSimple)
    left = vi[vn]
    return left, Distributions.loglikelihood(dist, left), vi
end

function assume(
    rng::Random.AbstractRNG,
    sampler::SampleFromPrior,
    dist::Distribution,
    vn::VarName,
    vi::SimpleOrThreadSafeSimple,
)
    value = init(rng, dist, sampler)
    vi = BangBang.push!!(vi, vn, value, dist, sampler)
    return value, Distributions.loglikelihood(dist, value), vi
end

function dot_assume(
    dist::MultivariateDistribution,
    var::AbstractMatrix,
    vns::AbstractVector{<:VarName},
    vi::SimpleOrThreadSafeSimple,
)
    @assert length(dist) == size(var, 1)
    # NOTE: We cannot work with `var` here because we might have a model of the form
    #
    #     m = Vector{Float64}(undef, n)
    #     m .~ Normal()
    #
    # in which case `var` will have `undef` elements, even if `m` is present in `vi`.
    value = vi[vns]
    lp = sum(zip(vns, eachcol(value))) do (vn, val)
        return Distributions.logpdf(dist, val)
    end
    return value, lp, vi
end

function dot_assume(
    dists::Union{Distribution,AbstractArray{<:Distribution}},
    var::AbstractArray,
    vns::AbstractArray{<:VarName},
    vi::SimpleOrThreadSafeSimple,
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

function dot_assume(
    rng,
    spl::Union{SampleFromPrior,SampleFromUniform},
    dists::Union{Distribution,AbstractArray{<:Distribution}},
    vns::AbstractArray{<:VarName},
    var::AbstractArray,
    vi::SimpleOrThreadSafeSimple,
)
    f = (vn, dist) -> init(rng, dist, spl)
    value = f.(vns, dists)
    vi = BangBang.setindex!!(vi, value, vns)
    lp = sum(Distributions.logpdf.(dists, value))
    return value, lp, vi
end

# HACK: Allows us to re-use the implementation of `dot_tilde`, etc. for literals.
increment_num_produce!(::SimpleOrThreadSafeSimple) = nothing
settrans!(vi::SimpleOrThreadSafeSimple, trans::Bool, vn::VarName) = nothing
istrans(::SimpleVarInfo, vn::VarName) = false

"""
    values_as(varinfo[, Type])

Return the values/realizations in `varinfo` as `Type`, if implemented.

If no `Type` is provided, return values as stored in `varinfo`.
"""
values_as(vi::SimpleVarInfo) = vi.values
values_as(vi::SimpleVarInfo, ::Type{Dict}) = Dict(pairs(vi.values))
values_as(vi::SimpleVarInfo, ::Type{NamedTuple}) = NamedTuple(pairs(vi.values))
values_as(vi::SimpleVarInfo{<:NamedTuple}, ::Type{NamedTuple}) = vi.values

"""
    logjoint(model::Model, θ)

Return the log joint probability of variables `θ` for the probabilistic `model`.

See [`logjoint`](@ref) and [`loglikelihood`](@ref).

# Examples
```jldoctest; setup=:(using Distributions)
julia> @model function demo(x)
           m ~ Normal()
           for i in eachindex(x)
               x[i] ~ Normal(m, 1.0)
           end
       end
demo (generic function with 2 methods)

julia> # Using a `NamedTuple`.
       logjoint(demo([1.0]), (m = 100.0, ))
-9902.33787706641

julia> # Using a `Dict`.
       logjoint(demo([1.0]), Dict(@varname(m) => 100.0))
-9902.33787706641

julia> # Truth.
       logpdf(Normal(100.0, 1.0), 1.0) + logpdf(Normal(), 100.0)
-9902.33787706641
```
"""
logjoint(model::Model, θ) = logjoint(model, SimpleVarInfo(θ))

"""
    logprior(model::Model, θ)

Return the log prior probability of variables `θ` for the probabilistic `model`.

See also [`logjoint`](@ref) and [`loglikelihood`](@ref).

# Examples
```jldoctest; setup=:(using Distributions)
julia> @model function demo(x)
           m ~ Normal()
           for i in eachindex(x)
               x[i] ~ Normal(m, 1.0)
           end
       end
demo (generic function with 2 methods)

julia> # Using a `NamedTuple`.
       logprior(demo([1.0]), (m = 100.0, ))
-5000.918938533205

julia> # Using a `Dict`.
       logprior(demo([1.0]), Dict(@varname(m) => 100.0))
-5000.918938533205

julia> # Truth.
       logpdf(Normal(), 100.0)
-5000.918938533205
```
"""
logprior(model::Model, θ) = logprior(model, SimpleVarInfo(θ))

"""
    loglikelihood(model::Model, θ)

Return the log likelihood of variables `θ` for the probabilistic `model`.

See also [`logjoint`](@ref) and [`logprior`](@ref).

# Examples
```jldoctest; setup=:(using Distributions)
julia> @model function demo(x)
           m ~ Normal()
           for i in eachindex(x)
               x[i] ~ Normal(m, 1.0)
           end
       end
demo (generic function with 2 methods)

julia> # Using a `NamedTuple`.
       loglikelihood(demo([1.0]), (m = 100.0, ))
-4901.418938533205

julia> # Using a `Dict`.
       loglikelihood(demo([1.0]), Dict(@varname(m) => 100.0))
-4901.418938533205

julia> # Truth.
       logpdf(Normal(100.0, 1.0), 1.0)
-4901.418938533205
```
"""
Distributions.loglikelihood(model::Model, θ) = loglikelihood(model, SimpleVarInfo(θ))
