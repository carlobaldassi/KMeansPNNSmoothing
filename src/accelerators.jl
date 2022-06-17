struct Naive <: Accelerator
    config::Configuration
end

Naive(centroids::Matrix{Float64}, n::Int) = Naive()
Base.copy(accel::Naive) = accel
reset!(accel::Naive) = accel

struct ReducedComparison <: Accelerator
    config::Configuration
    active::BitVector
    ReducedComparison(config::Configuration) = new(config, trues(size(config.centroids,2)))
    Base.copy(accel::ReducedComparison) = new(accel.config, copy(accel.active))
end

reset!(accel::ReducedComparison) = (fill!(accel.active, true); accel)

struct KBall <: Accelerator
    config::Configuration{KBall}
    δc::Vector{Float64}
    r::Vector{Float64}
    cdist::Matrix{Float64}
    neighb::Vector{Vector{Int}}
    stable::BitVector
    nstable::BitVector
    function KBall(config::Configuration)
        @extract config : centroids
        m, k = size(centroids)
        δc = zeros(k)
        r = fill(Inf, k)
        cdist = [@inbounds @views √_cost(centroids[:,i], centroids[:,j]) for i = 1:k, j = 1:k] # TODO
        neighb = [deleteat!(collect(1:k), j) for j = 1:k]
        stable = falses(k)
        nstable = falses(k)
        return new(config, δc, r, cdist, neighb, stable, nstable)
    end
    function Base.copy(accel::KBall)
        @extract accel : config δc r cdist neighb stable nstable
        return new(config, copy(δc), copy(r), copy(cdist), copy.(neighb), copy(stable), copy(nstable))
    end
end

function reset!(accel::KBall)
    @extract accel : config δc r cdist neighb stable nstable
    @extract config : k centroids
    fill!(δc, 0.0)
    fill!(r, Inf)
    @inbounds for j = 1:k, i = 1:k
        cdist[i,j] = √_cost(centroids[:,i], centroids[:,j])
    end
    neighb .= [deleteat!(collect(1:k), j) for j = 1:k]
    fill!(stable, false)
    fill!(nstable, false)
    return accel
end

struct Hamerly <: Accelerator
    config::Configuration{Hamerly}
    δc::Vector{Float64}
    lb::Vector{Float64}
    ub::Vector{Float64}
    s::Vector{Float64}
    function Hamerly(config::Configuration)
        @extract config : n k centroids
        δc = zeros(k)
        lb = zeros(n)
        ub = fill(Inf, n)
        s = [@inbounds @views √(minimum(j′ ≠ j ? _cost(centroids[:,j], centroids[:,j′]) : Inf for j′ = 1:k)) for j = 1:k]
        return new(config, δc, lb, ub, s)
    end
    function Base.copy(accel::Hamerly) 
        @extract accel : config δc lb ub s
        return new(accel.config, copy(δc), copy(lb), copy(ub), copy(s))
    end
end

function reset!(accel::Hamerly)
    @extract accel : config δc lb ub s
    @extract config : k centroids
    fill!(δc, 0.0)
    fill!(lb, 0.0)
    fill!(ub, Inf)
    @inbounds for j = 1:k
        s[j] = @views √minimum(j′ ≠ j ? _cost(centroids[:,j], centroids[:,j′]) : Inf for j′ = 1:k)
    end
    return accel
end


struct SHam <: Accelerator
    config::Configuration{SHam}
    δc::Vector{Float64}
    lb::Vector{Float64}
    s::Vector{Float64}
    function SHam(config::Configuration)
        @extract config : n k centroids
        δc = zeros(k)
        lb = zeros(n)
        s = [@inbounds @views √(minimum(j′ ≠ j ? _cost(centroids[:,j], centroids[:,j′]) : Inf for j′ = 1:k)) for j = 1:k]
        return new(config, δc, lb, s)
    end
    function Base.copy(accel::SHam) 
        @extract accel : config δc lb s
        return new(accel.config, copy(δc), copy(lb), copy(s))
    end
end

function reset!(accel::SHam)
    @extract accel : config δc lb s
    @extract config : k cnentroids
    fill!(δc, 0.0)
    fill!(lb, 0.0)
    @inbounds for j = 1:k
        s[j] = @views √minimum(j′ ≠ j ? _cost(centroids[:,j], centroids[:,j′]) : Inf for j′ = 1:k)
    end
    return accel
end

struct SElk <: Accelerator
    config::Configuration{SElk}
    δc::Vector{Float64}
    lb::Matrix{Float64}
    ub::Vector{Float64}
    function SElk(config::Configuration)
        @extract config : n k centroids
        δc = zeros(k)
        lb = zeros(k, n)
        ub = fill(Inf, n)
        return new(config, δc, lb, ub)
    end
    function Base.copy(accel::SElk)
        @extract accel : config δc ls ub
        return new(accel.config, copy(δc), copy(lb), copy(ub))
    end
end

function reset!(accel::SElk)
    @extract accel : δc lb ub
    fill!(δc, 0.0)
    fill!(lb, 0.0)
    fill!(ub, Inf)
    return accel
end


struct RElk <: Accelerator
    config::Configuration{RElk}
    δc::Vector{Float64}
    lb::Matrix{Float64}
    active::BitVector
    function RElk(config::Configuration)
        @extract config : n k
        δc = zeros(k)
        lb = zeros(k, n)
        active = trues(k)
        return new(config, δc, lb, active)
    end
    function Base.copy(accel::RElk) 
        @extract accel : config δc lb active
        return new(accel.config, copy(δc), copy(lb), copy(active))
    end
end

function reset!(accel::RElk)
    @extract accel : δc lb active
    fill!(δc, 0.0)
    fill!(lb, 0.0)
    fill!(active, true)
    return accel
end


function gen_groups(k, G)
    b = k÷G
    r = k - b*G
    # gr = [(1:(b+(f≤r))) .+ (f≤r ? (b+1)*(f-1) : (b+1)*r + b*(f-r-1)) for f = 1:G]
    groups = [(1:(b+(f≤r))) .+ ((b+1)*(f-1) - max(f-r-1,0)) for f = 1:G]
    @assert vcat(groups...) == 1:k gr,vcat(groups...),1:k
    return groups
end

struct Yinyang <: Accelerator
    config::Configuration{Yinyang}
    G::Int
    δc::Vector{Float64}
    δcₘ::Vector{Float64}
    δcₛ::Vector{Float64}
    jₘ::Vector{Float64}
    ub::Vector{Float64}
    groups::Vector{UnitRange{Int}}
    gind::Vector{Int}
    lb::Matrix{Float64}
    function Yinyang(config::Configuration)
        @extract config : n k centroids
        G = max(1, round(Int, k / 10))
        δc = zeros(k)
        δcₘ = zeros(G)
        δcₛ = zeros(G)
        jₘ = zeros(Int, G)
        ub = fill(Inf, n)
        gind = zeros(Int, n)
        lb = zeros(G, n)

        if G > 1
            result = kmeans(centroids, G; kmseeder=KMPlusPlus{1}(), verbose=true, accel=ReducedComparison)
            groups = UnitRange{Int}[]
            new_centroids = similar(centroids)
            ind = 0
            for f = 1:G
                gr_inds = findall(result.labels .== f)
                gr_size = length(gr_inds)
                r = ind .+ (1:gr_size)
                new_centroids[:,r] = centroids[:,gr_inds]
                push!(groups, r)
                ind += gr_size
            end
            # @assert vcat(groups...) == 1:k
            centroids .= new_centroids
        end
        return new(config, G, δc, δcₘ, δcₛ, jₘ, ub, groups, gind, lb)
    end
    function Base.copy(accel::Yinyang)
        @extract accel : config δc δcₘ δcₛ jₘ ub gind lb
        return new(config, G, copy(δc), copy(δcₘ), copy(δcₛ), copy(jₘ), copy(ub), copy(gind), copy(lb))
    end

end

function reset!(config::Configuration)
    @extract accel : config δc δcₘ δcₛ jₘ ub gind lb
    fill!(δc, 0.0)
    fill!(δcₘ, 0.0)
    fill!(δcₛ, 0.0)
    fill!(jₘ, 0)
    fill!(ub, Inf)
    fill!(gind, 0)
    fill!(lb, 0.0)
    return accel
end
