# methods
abstract type AbstractESSMethod end

const _DOC_SPLIT_CHAINS =
    """`split_chains` indicates the number of chains each chain is split into.
    When `split_chains > 1`, then the diagnostics check for within-chain convergence. When
    `d = mod(draws, split_chains) > 0`, i.e. the chains cannot be evenly split, then 1 draw
    is discarded after each of the first `d` splits within each chain."""

"""
    ESSMethod <: AbstractESSMethod

The `ESSMethod` uses a standard algorithm for estimating the
effective sample size of MCMC chains.

It is is based on the discussion by [^VehtariGelman2021] and uses the
biased estimator of the autocovariance, as discussed by [^Geyer1992].

[^VehtariGelman2021]: Vehtari, A., Gelman, A., Simpson, D., Carpenter, B., & Bürkner, P. C. (2021).
    Rank-normalization, folding, and localization: An improved ``\\widehat {R}`` for
    assessing convergence of MCMC. Bayesian Analysis.
    doi: [10.1214/20-BA1221](https://doi.org/10.1214/20-BA1221)
    arXiv: [1903.08008](https://arxiv.org/abs/1903.08008)
[^Geyer1992]: Geyer, C. J. (1992). Practical Markov Chain Monte Carlo. Statistical Science, 473-483.
"""
struct ESSMethod <: AbstractESSMethod end

"""
    FFTESSMethod <: AbstractESSMethod

The `FFTESSMethod` uses a standard algorithm for estimating
the effective sample size of MCMC chains.

The algorithm is the same as the one of [`ESSMethod`](@ref) but this method uses fast
Fourier transforms (FFTs) for estimating the autocorrelation.

!!! info
    To be able to use this method, you have to load a package that implements the
    [AbstractFFTs.jl](https://github.com/JuliaMath/AbstractFFTs.jl) interface such
    as [FFTW.jl](https://github.com/JuliaMath/FFTW.jl) or
    [FastTransforms.jl](https://github.com/JuliaApproximation/FastTransforms.jl).
"""
struct FFTESSMethod <: AbstractESSMethod end

"""
    BDAESSMethod <: AbstractESSMethod

The `BDAESSMethod` uses a standard algorithm for estimating the effective sample size of
MCMC chains.

It is is based on the discussion by [^VehtariGelman2021]. and uses the
variogram estimator of the autocorrelation function discussed by [^BDA3].

[^VehtariGelman2021]: Vehtari, A., Gelman, A., Simpson, D., Carpenter, B., & Bürkner, P. C. (2021).
    Rank-normalization, folding, and localization: An improved ``\\widehat {R}`` for
    assessing convergence of MCMC. Bayesian Analysis.
    doi: [10.1214/20-BA1221](https://doi.org/10.1214/20-BA1221)
    arXiv: [1903.08008](https://arxiv.org/abs/1903.08008)
[^BDA3]: Gelman, A., Carlin, J. B., Stern, H. S., Dunson, D. B., Vehtari, A., & Rubin, D. B. (2013). Bayesian data analysis. CRC press.
"""
struct BDAESSMethod <: AbstractESSMethod end

# caches
struct ESSCache{T,S}
    samples::Matrix{T}
    chain_var::Vector{S}
end

struct FFTESSCache{T,S,C,P,I}
    samples::Matrix{T}
    chain_var::Vector{S}
    samples_cache::C
    plan::P
    invplan::I
end

mutable struct BDAESSCache{T,S,M}
    samples::Matrix{T}
    chain_var::Vector{S}
    mean_chain_var::M
end

function build_cache(::ESSMethod, samples::Matrix, var::Vector)
    # check arguments
    niter, nchains = size(samples)
    length(var) == nchains || throw(DimensionMismatch())

    return ESSCache(samples, var)
end

function build_cache(::FFTESSMethod, samples::Matrix, var::Vector)
    # check arguments
    niter, nchains = size(samples)
    length(var) == nchains || throw(DimensionMismatch())

    # create cache for FFT
    T = complex(eltype(samples))
    n = nextprod([2, 3], 2 * niter - 1)
    samples_cache = Matrix{T}(undef, n, nchains)

    # create plans of FFTs
    fft_plan = AbstractFFTs.plan_fft!(samples_cache, 1)
    ifft_plan = AbstractFFTs.plan_ifft!(samples_cache, 1)

    return FFTESSCache(samples, var, samples_cache, fft_plan, ifft_plan)
end

function build_cache(::BDAESSMethod, samples::Matrix, var::Vector)
    # check arguments
    nchains = size(samples, 2)
    length(var) == nchains || throw(DimensionMismatch())

    return BDAESSCache(samples, var, Statistics.mean(var))
end

update!(cache::ESSCache) = nothing

function update!(cache::FFTESSCache)
    # copy samples and add zero padding
    samples = cache.samples
    samples_cache = cache.samples_cache
    niter, nchains = size(samples)
    n = size(samples_cache, 1)
    T = eltype(samples_cache)
    @inbounds for j in 1:nchains
        for i in 1:niter
            samples_cache[i, j] = samples[i, j]
        end
        for i in (niter + 1):n
            samples_cache[i, j] = zero(T)
        end
    end

    # compute unnormalized autocovariance
    cache.plan * samples_cache
    @. samples_cache = abs2(samples_cache)
    cache.invplan * samples_cache

    return nothing
end

function update!(cache::BDAESSCache)
    # recompute mean of within-chain variances
    cache.mean_chain_var = Statistics.mean(cache.chain_var)

    return nothing
end

function mean_autocov(k::Int, cache::ESSCache)
    # check arguments
    samples = cache.samples
    niter, nchains = size(samples)
    0 ≤ k < niter || throw(ArgumentError("only lags ≥ 0 and < $niter are supported"))

    # compute mean of unnormalized autocovariance estimates
    firstrange = 1:(niter - k)
    lastrange = (k + 1):niter
    s = Statistics.mean(1:nchains) do i
        return @inbounds LinearAlgebra.dot(
            view(samples, firstrange, i), view(samples, lastrange, i)
        )
    end

    # normalize autocovariance estimators by `niter` instead of `niter - k` to obtain biased
    # but more stable estimators for all lags as discussed by Geyer (1992)
    return s / niter
end

function mean_autocov(k::Int, cache::FFTESSCache)
    # check arguments
    niter, nchains = size(cache.samples)
    0 ≤ k < niter || throw(ArgumentError("only lags ≥ 0 and < $niter are supported"))

    # compute mean autocovariance
    # we use biased but more stable estimators as discussed by Geyer (1992)
    samples_cache = cache.samples_cache
    chain_var = cache.chain_var
    uncorrection_factor = (niter - 1)//niter  # undo corrected=true for chain_var
    result = Statistics.mean(1:nchains) do i
        @inbounds(real(samples_cache[k + 1, i]) / real(samples_cache[1, i])) * chain_var[i]
    end
    return result * uncorrection_factor
end

function mean_autocov(k::Int, cache::BDAESSCache)
    # check arguments
    samples = cache.samples
    niter, nchains = size(samples)
    0 ≤ k < niter || throw(ArgumentError("only lags ≥ 0 and < $niter are supported"))

    # compute mean autocovariance
    n = niter - k
    idxs = 1:n
    s = Statistics.mean(1:nchains) do j
        return sum(idxs) do i
            @inbounds abs2(samples[i, j] - samples[k + i, j])
        end
    end

    return cache.mean_chain_var - s / (2 * n)
end

"""
    ess(
        samples::AbstractArray{<:Union{Missing,Real},3};
        type=:bulk,
        [estimator,]
        method=ESSMethod(),
        split_chains::Int=2,
        maxlag::Int=250,
        kwargs...
    )

Estimate the effective sample size (ESS) of the `samples` of shape
`(draws, chains, parameters)` with the `method`.

Optionally, only one of the `type` of ESS estimate to return or the `estimator` for which
ESS is computed can be specified (see below). Some `type`s accept additional `kwargs`.

$_DOC_SPLIT_CHAINS There must be at least 3 draws in each chain after splitting.

`maxlag` indicates the maximum lag for which autocovariance is computed and must be greater
than 0.

For a given estimand, it is recommended that the ESS is at least `100 * chains` and that
``\\widehat{R} < 1.01``.[^VehtariGelman2021]

See also: [`ESSMethod`](@ref), [`FFTESSMethod`](@ref), [`BDAESSMethod`](@ref),
[`rhat`](@ref), [`ess_rhat`](@ref), [`mcse`](@ref)

## Estimators

The ESS and ``\\widehat{R}`` values can be computed for the following estimators:
- `Statistics.mean`
- `Statistics.median`
- `Statistics.std`
- `StatsBase.mad`
- `Base.Fix2(Statistics.quantile, p::Real)`

## Types

If no `estimator` is provided, the following types of ESS estimates may be computed:
- `:bulk`/`:rank`: mean-ESS computed on rank-normalized draws. This type diagnoses poor
    convergence in the bulk of the distribution due to trends or different locations of the
    chains.
- `:tail`: minimum of the quantile-ESS for the symmetric quantiles where
    `tail_prob=0.1` is the probability in the tails. This type diagnoses poor convergence in
    the tails of the distribution. If this type is chosen, `kwargs` may contain a
    `tail_prob` keyword.
- `:basic`: basic ESS, equivalent to specifying `estimator=Statistics.mean`.

While Bulk-ESS is conceptually related to basic ESS, it is well-defined even if the chains
do not have finite variance.[^VehtariGelman2021]. For each parameter, rank-normalization
proceeds by first ranking the inputs using "tied ranking" and then transforming the ranks to
normal quantiles so that the result is standard normally distributed. This transform is
monotonic.

[^VehtariGelman2021]: Vehtari, A., Gelman, A., Simpson, D., Carpenter, B., & Bürkner, P. C. (2021).
    Rank-normalization, folding, and localization: An improved ``\\widehat {R}`` for
    assessing convergence of MCMC. Bayesian Analysis.
    doi: [10.1214/20-BA1221](https://doi.org/10.1214/20-BA1221)
    arXiv: [1903.08008](https://arxiv.org/abs/1903.08008)
"""
@constprop :aggressive function ess(
    samples::AbstractArray{<:Union{Missing,Real},3};
    estimator=nothing,
    type=nothing,
    kwargs...,
)
    if estimator !== nothing && type !== nothing
        throw(ArgumentError("only one of `estimator` and `type` can be specified"))
    elseif estimator !== nothing
        return _ess(estimator, samples; kwargs...)
    elseif type !== nothing
        return _ess(_val(type), samples; kwargs...)
    else
        return _ess(Val(:basic), samples; kwargs...)
    end
end
function _ess(estimator, samples::AbstractArray{<:Union{Missing,Real},3}; kwargs...)
    x = _expectand_proxy(estimator, samples)
    if x === nothing
        throw(ArgumentError("the estimator $estimator is not yet supported by `ess`"))
    end
    return _ess(Val(:basic), x; kwargs...)
end
function _ess(
    ::Val{T}, samples::AbstractArray{<:Union{Missing,Real},3}; kwargs...
) where {T}
    return throw(ArgumentError("the `type` `$T` is not supported by `ess`"))
end
function _ess(type::Val{:basic}, samples::AbstractArray{<:Union{Missing,Real},3}; kwargs...)
    return first(_ess_rhat(type, samples; kwargs...))
end
function _ess(type::Val{:bulk}, samples::AbstractArray{<:Union{Missing,Real},3}; kwargs...)
    return first(_ess_rhat(type, samples; kwargs...))
end
function _ess(
    ::Val{:tail},
    x::AbstractArray{<:Union{Missing,Real},3};
    tail_prob::Real=1//10,
    kwargs...,
)
    # workaround for https://github.com/JuliaStats/Statistics.jl/issues/136
    T = Base.promote_eltype(x, tail_prob)
    pl = convert(T, tail_prob / 2)
    pu = convert(T, 1 - tail_prob / 2)
    S_lower = _ess(Base.Fix2(Statistics.quantile, pl), x; kwargs...)
    S_upper = _ess(Base.Fix2(Statistics.quantile, pu), x; kwargs...)
    return map(min, S_lower, S_upper)
end
function _ess(::Val{:rank}, samples::AbstractArray{<:Union{Missing,Real},3}; kwargs...)
    return _ess(Val(:bulk), samples; kwargs...)
end

"""
    ess_rhat(samples::AbstractArray{<:Union{Missing,Real},3}; type=:rank, kwargs...)

Estimate the effective sample size and ``\\widehat{R}`` of the `samples` of shape
`(draws, chains, parameters)` with the `method`.

When both ESS and ``\\widehat{R}`` are needed, this method is often more efficient than
calling `ess` and `rhat` separately.

See [`rhat`](@ref) for a description of supported `type`s and [`ess`](@ref) for a
description of `kwargs`.
"""
@constprop :aggressive function ess_rhat(
    samples::AbstractArray{<:Union{Missing,Real},3}; type=Val(:rank), kwargs...
)
    return _ess_rhat(_val(type), samples; kwargs...)
end
function _ess_rhat(
    ::Val{T}, samples::AbstractArray{<:Union{Missing,Real},3}; kwargs...
) where {T}
    return throw(ArgumentError("the `type` `$T` is not supported by `ess_rhat`"))
end
function _ess_rhat(
    ::Val{:basic},
    chains::AbstractArray{<:Union{Missing,Real},3};
    method::AbstractESSMethod=ESSMethod(),
    split_chains::Int=2,
    maxlag::Int=250,
)
    # compute size of matrices (each chain may be split!)
    niter = size(chains, 1) ÷ split_chains
    nchains = split_chains * size(chains, 2)
    ntotal = niter * nchains
    axes_out = (axes(chains, 3),)
    T = promote_type(eltype(chains), typeof(zero(eltype(chains)) / 1))

    # discard the last pair of autocorrelations, which are poorly estimated and only matter
    # when chains have mixed poorly anyways.
    # leave the last even autocorrelation as a bias term that reduces variance for
    # case of antithetical chains, see below
    if !(niter > 4)
        throw(ArgumentError("number of draws after splitting must >4 but is $niter."))
    end
    maxlag > 0 || throw(DomainError(maxlag, "maxlag must be >0."))
    maxlag = min(maxlag, niter - 4)

    # define output arrays
    ess = similar(chains, T, axes_out)
    rhat = similar(chains, T, axes_out)

    T === Missing && return ess, rhat

    # define caches for mean and variance
    chain_mean = Array{T}(undef, 1, nchains)
    chain_var = Array{T}(undef, nchains)
    samples = Array{T}(undef, niter, nchains)

    # compute correction factor
    correctionfactor = (niter - 1)//niter

    # define cache for the computation of the autocorrelation
    esscache = build_cache(method, samples, chain_var)

    # set maximum ess for antithetic chains, see below
    ess_max = ntotal * log10(oftype(one(T), ntotal))

    # for each parameter
    for (i, chains_slice) in zip(eachindex(ess), eachslice(chains; dims=3))
        # check that no values are missing
        if any(x -> x === missing, chains_slice)
            rhat[i] = missing
            ess[i] = missing
            continue
        end

        # split chains
        copyto_split!(samples, chains_slice)

        # calculate mean of chains
        Statistics.mean!(chain_mean, samples)

        # calculate within-chain variance
        @inbounds for j in 1:nchains
            chain_var[j] = Statistics.var(
                view(samples, :, j); mean=chain_mean[j], corrected=true
            )
        end
        W = Statistics.mean(chain_var)

        # compute variance estimator var₊, which accounts for between-chain variance as well
        # avoid NaN when nchains=1 and set the variance estimator var₊ to the the within-chain variance in that case
        var₊ = correctionfactor * W + Statistics.var(chain_mean; corrected=(nchains > 1))
        inv_var₊ = inv(var₊)

        # estimate rhat
        rhat[i] = sqrt(var₊ / W)

        # center the data around 0
        samples .-= chain_mean

        # update cache
        update!(esscache)

        # compute the first two autocorrelation estimates
        # by combining autocorrelation (or rather autocovariance) estimates of each chain
        ρ_odd = 1 - inv_var₊ * (W - mean_autocov(1, esscache))
        ρ_even = one(ρ_odd) # estimate at lag 0 is known

        # sum correlation estimates
        pₜ = ρ_even + ρ_odd
        sum_pₜ = pₜ

        k = 2
        while k < (maxlag - 1)
            # compute subsequent autocorrelation of all chains
            # by combining estimates of each chain
            ρ_even = 1 - inv_var₊ * (W - mean_autocov(k, esscache))
            ρ_odd = 1 - inv_var₊ * (W - mean_autocov(k + 1, esscache))

            # stop summation if p becomes non-positive
            Δ = ρ_even + ρ_odd
            Δ > zero(Δ) || break

            # generate a monotone sequence
            pₜ = min(Δ, pₜ)

            # update sum
            sum_pₜ += pₜ

            # update indices
            k += 2
        end
        # for antithetic chains
        # - reduce variance by averaging truncation to odd lag and truncation to next even lag
        # - prevent negative ESS for short chains by ensuring τ is nonnegative
        # See discussions in:
        # - § 3.2 of Vehtari et al. https://arxiv.org/pdf/1903.08008v5.pdf
        # - https://github.com/TuringLang/MCMCDiagnosticTools.jl/issues/40
        # - https://github.com/stan-dev/rstan/pull/618
        # - https://github.com/stan-dev/stan/pull/2774
        ρ_even = maxlag > 1 ? 1 - inv_var₊ * (W - mean_autocov(k, esscache)) : zero(ρ_even)
        τ = max(0, 2 * sum_pₜ + max(0, ρ_even) - 1)

        # estimate the effective sample size
        ess[i] = min(ntotal / τ, ess_max)
    end

    return ess, rhat
end
function _ess_rhat(::Val{:bulk}, x::AbstractArray{<:Union{Missing,Real},3}; kwargs...)
    return _ess_rhat(Val(:basic), _rank_normalize(x); kwargs...)
end
function _ess_rhat(
    type::Val{:tail},
    x::AbstractArray{<:Union{Missing,Real},3};
    split_chains::Int=2,
    kwargs...,
)
    S = _ess(type, x; split_chains=split_chains, kwargs...)
    R = _rhat(type, x; split_chains=split_chains)
    return S, R
end
function _ess_rhat(
    ::Val{:rank}, x::AbstractArray{<:Union{Missing,Real},3}; split_chains::Int=2, kwargs...
)
    Sbulk, Rbulk = _ess_rhat(Val(:bulk), x; split_chains=split_chains, kwargs...)
    Rtail = _rhat(Val(:tail), x; split_chains=split_chains)
    Rrank = map(max, Rtail, Rbulk)
    return Sbulk, Rrank
end

# Compute an expectand `z` such that ``\\textrm{mean-ESS}(z) ≈ \\textrm{f-ESS}(x)``.
# If no proxy expectand for `f` is known, `nothing` is returned.
_expectand_proxy(f, x) = nothing
_expectand_proxy(::typeof(Statistics.mean), x) = x
function _expectand_proxy(::typeof(Statistics.median), x)
    y = similar(x)
    # avoid using the `dims` keyword for median because it
    # - can error for Union{Missing,Real} (https://github.com/JuliaStats/Statistics.jl/issues/8)
    # - is type-unstable (https://github.com/JuliaStats/Statistics.jl/issues/39)
    for (xi, yi) in zip(eachslice(x; dims=3), eachslice(y; dims=3))
        yi .= xi .≤ Statistics.median(vec(xi))
    end
    return y
end
function _expectand_proxy(::typeof(Statistics.std), x)
    return (x .- Statistics.mean(x; dims=(1, 2))) .^ 2
end
function _expectand_proxy(::typeof(StatsBase.mad), x)
    x_folded = _fold_around_median(x)
    return _expectand_proxy(Statistics.median, x_folded)
end
function _expectand_proxy(f::Base.Fix2{typeof(Statistics.quantile),<:Real}, x)
    y = similar(x)
    # currently quantile does not support a dims keyword argument
    for (xi, yi) in zip(eachslice(x; dims=3), eachslice(y; dims=3))
        if any(ismissing, xi)
            # quantile function raises an error if there are missing values
            fill!(yi, missing)
        else
            yi .= xi .≤ f(vec(xi))
        end
    end
    return y
end