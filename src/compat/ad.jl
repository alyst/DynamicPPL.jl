# Prevent Zygote from differentiating push!
# See https://github.com/TuringLang/Turing.jl/issues/1199
ZygoteRules.@adjoint function push!(
    vi::VarInfo,
    vn::VarName,
    r,
    dist::Distribution,
    gidset::Set{Selector}
)
    return push!(vi, vn, r, dist, gidset), _ -> nothing
end

ZygoteRules.@adjoint function Threads.nthreads()
    return Threads.nthreads(), _ -> nothing
end
ZygoteRules.@adjoint function Threads.threadid()
    return Threads.threadid(), _ -> nothing
end
