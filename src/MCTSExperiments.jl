module MCTSExperiments

#repository from book authors https://github.com/algorithmsbooks/DecisionMakingProblems.jl which contains some of the basic functions and data structures and functions in the book as well as game environments
using DecisionMakingProblems
using Base.Threads
using ThreadPools
using Distributed
using Base.Threads
using TailRec

export DecisionMakingProblems, MDP, MonteCarloTreeSearch, MCTSPar, init_MCTSPar, rollout, UCT, LeafP, RootP, TreeP, WU_UCT, VL_UCT_hard, VL_UCT_soft, BU_UCT, clear_dicts!

transition_and_reward = DecisionMakingProblems.transition_and_reward
#goal is to first use the basic functionality in the game2048 forked package and put it into a structure where the code from the algorithms book can be used with it

#the following code is copied from Appendix G.5 of the book found here: https://algorithmsbook.com/
function Base.findmax(f::Function, xs)
    f_max = -Inf
    x_max = first(xs)
    for x in xs
        v = f(x)
        if v > f_max
            f_max, x_max = v, x
        end
    end
    return f_max, x_max
end

Base.argmax(f::Function, xs) = findmax(f, xs)[2]

#the following code is copied from Chapter 7 of the book found here: https://algorithmsbook.com/
# struct MDP
#     Ī³ # discount factor
#     š® # state space
#     š # action space
#     T # transition function
#     R # reward function
#     TR # sample transition and reward
# end
import DecisionMakingProblems.MDP #same struct as found in their module

function lookahead(š«::MDP, U, s, a)
    š®, T, R, Ī³ = š«.š®, š«.T, š«.R, š«.Ī³
    return R(s,a) + Ī³*sum(T(s,a,sā²)*U(sā²) for sā² in š®)
end

function lookahead(š«::MDP, U::Vector, s, a)
    š®, T, R, Ī³ = š«.š®, š«.T, š«.R, š«.Ī³
    return R(s,a) + Ī³*sum(T(s,a,sā²)*U[i] for (i,sā²) in enumerate(š®))
end

struct ValueFunctionPolicy
    š« # problem
    U # utility function
end

function greedy(š«::MDP, U, s)
    u, a = findmax(a->lookahead(š«, U, s, a), š«.š)
    return (a=a, u=u)
end

#following code is copied from Chapter 9 of the book found here: https://algorithmsbook.com/

#forward search functions
struct RolloutLookahead
    š« # problem
    Ļ # rollout policy
    d # depth
end

randstep(š«::MDP, s, a) = š«.TR(s, a)

function rollout(TR, Ī³, s, Ļ, d, isterminal::Function = s -> false)
    ret = 0.0
    t = 1
    while !isterminal(s) && (t <= d)
        a = Ļ(s)
        s, r = TR(s, a)
        ret += Ī³^(t-1) * r
        t += 1
    end
    return (ret, t-1, s)
end

function rollout(TR, Ī³, s, Ļ, isterminal::Function = s -> false)
    ret = 0.0
    t = 1
    while !isterminal(s)
        a = Ļ(s)
        s, r = TR(s, a)
        ret += Ī³^(t-1) * r
        t += 1
    end
    return (ret, t-1, s)
end

function (Ļ::RolloutLookahead)(s)
    U(s) = rollout(Ļ.š«, s, Ļ.Ļ, Ļ.d)
    return greedy(Ļ.š«, U, s).a
end

#= 
need to understand the convensions in this struct to see how to define all the components
what does š« need to have?
š«.š, š«.TR, š«.Ī³

what does N need to have?
N[(s,a)], so a dictionary of counts indexed by state/action pairs

what does Q need to have?
Q[(s,a)], so it is the same structure as N, clearly Q is not a function on state/action pairs but just a lookup

d and m should just be integers
=#

struct MonteCarloTreeSearch
    š«::MDP # problem
    N::Dict # visit counts
    Q::Dict # action value estimates
    d::Integer # depth
    m::Integer # number of simulations
    c::AbstractFloat # exploration constant
    U::Function # value function estimate
end

abstract type MCTSAlgo end

# data structure to accomodate generalized parallel MCTS algorithm published here: https://arxiv.org/abs/2006.08785
struct MCTSPar{T <: MCTSAlgo} 
    š«::MDP # problem
    N::Vector{Dict}  # visit counts
    Q::Vector{Dict}  # action value estimates
    O::Vector{Dict}  #on-going simulations 
    O_bar::Vector{Dict} #average across rollouts of on-going simulations
    R::Vector{Dict} #tree sync stats
    d::Integer # depth
    m::Integer # number of simulations
    c::AbstractFloat # exploration constant
    U::Function # value function estimate
    F::Vector{Union{Task, Nothing}} # keeps track of each simulator whether it is occupied, ready to have results fetched, or unassigned
    M # number of search trees
    algo::T
end



function init_MCTSPar(š«::MDP, rootstate::S, U::Function, numtrees::Integer, numsims::Integer, algo::T; d = 10, c = 10., m = 1000) where T <: MCTSAlgo where S 
    Action = eltype(š«.š)
    N = [Dict{Tuple{S, Action}, Int64}() for _ in 1:numtrees]
    Q = [Dict{Tuple{S, Action}, Float64}() for _ in 1:numtrees]
    O = [Dict{Tuple{S, Action}, Int64}() for _ in 1:numtrees]
    O_bar = [Dict{Tuple{S, Action}, Float64}() for _ in 1:numtrees]
    R = [Dict{Tuple{S, Action}, Vector{Tuple{Float64, Int64}}}() for _ in 1:numtrees]
    F = Vector{Union{Task, Nothing}}(undef, numsims)
    fill!(F, nothing)
    MCTSPar{T}(š«, N, Q, O, O_bar, R, d, m, c, U, F, numtrees, algo)
end



struct UCT <: MCTSAlgo end 
struct LeafP <: MCTSAlgo end
struct RootP <: MCTSAlgo end
struct TreeP <: MCTSAlgo end 
struct WU_UCT <: MCTSAlgo end
struct VL_UCT_hard <: MCTSAlgo
    r #virtual loss
end
struct VL_UCT_soft <: MCTSAlgo
    r #virtual loss
    n #soft adjustment parameter
end
struct BU_UCT <: MCTSAlgo
    m_max #ā(0,1)
end

calc_Ļ_syn(::MCTSPar) = 1
calc_Ļ_syn(pol::MCTSPar{LeafP}) = pol.M 
calc_Ļ_syn(pol::MCTSPar{RootP}) = pol.m

f_sel(pol::MCTSPar, m1, m2) = 1
f_sel(pol::MCTSPar{LeafP}, m1, m2) = (m1 + 1) % pol.M 
f_sel(pol::MCTSPar{RootP}, m1, m2) = m1
f_sel(pol::MCTSPar{T}, m1, m2) where T <: Union{TreeP, WU_UCT, VL_UCT_hard, VL_UCT_soft} = rand(1:pol.M)

calcQĢ(pol::MCTSPar, s_a, m) = 0.0
calcQĢ(pol::MCTSPar{T}, s_a, m) where T <: Union{VL_UCT_hard, VL_UCT_soft} = -pol.algo.r 
calcQĢ(pol::MCTSPar{BU_UCT}, s_a, m) = 1.0 

calcNĢ(pol::MCTSPar, s_a, m) = 0
calcNĢ(pol::MCTSPar{T}, s_a, m) where T <: Union{WU_UCT, BU_UCT} = pol.O[m][s_a]
calcNĢ(pol::MCTSPar{VL_UCT_soft}, s_a, m) = pol.algo.n*pol.O[m][s_a]

Ī±(pol::MCTSPar, s_a, m) = 1. 
Ī±(pol::MCTSPar{VL_UCT_soft}, s_a, m) = pol.N[m][s_a] / (pol.N[m][s_a] + pol.algo.n*pol.O[m][s_a]) 

Ī²(pol::MCTSPar, s_a, m) = 0.
Ī²(pol::MCTSPar{VL_UCT_hard}, s_a, m) = pol.O[m][s_a] 
Ī²(pol::MCTSPar{VL_UCT_soft}, s_a, m) = pol.algo.n*pol.O[m][s_a] / (pol.N[m][s_a] + pol.algo.n*pol.O[m][s_a])
Ī²(pol::MCTSPar{BU_UCT}, s_a, m) = pol.O_bar[m][s_a] < pol.algo.m_max*length(pol.F) ? 0. : -Inf 

calcQĢ(pol::MCTSPar, s_a, m) = Ī±(pol, s_a, m)*pol.Q[m][s_a] + Ī²(pol, s_a, m)*calcQĢ(pol, s_a, m) 
calcNĢ(pol::MCTSPar, s_a, m) = pol.N[m][s_a] + calcNĢ(pol, s_a, m) 

function select_action(pol, m)
end

function (Ļ::MonteCarloTreeSearch)(s)
    for k in 1:Ļ.m
        simulate!(Ļ, s)
    end
    return argmax(a->Ļ.Q[(s,a)], Ļ.š«.š)
end

function (Ļ::MCTSPar)(s, clear_dicts=true)
    mcts_rollout!(Ļ::MCTSPar, s)
    Q = synctrees!(Ļ)
    action = argmax(a->Q[(s,a)], Ļ.š«.š)
    clear_dicts && clear_dicts!(Ļ)
    return action
end 

function simulate!(Ļ::MonteCarloTreeSearch, s, d=Ļ.d)
    if d ā¤ 0
        return Ļ.U(s)
    end
    š«, N, Q, c, O = Ļ.š«, Ļ.N, Ļ.Q, Ļ.c, Ļ.O
    š, TR, Ī³ = š«.š, š«.TR, š«.Ī³
    if !haskey(N, (s, first(š)))
        for a in š
            N[(s,a)] = 0
            Q[(s,a)] = 0.0
        end
        return Ļ.U(s)
    end
    a = explore(Ļ, s)
    sā², r = TR(s,a)
    q = r + Ī³*simulate!(Ļ, sā², d-1)
    N[(s,a)] += 1
    Q[(s,a)] += (q-Q[(s,a)])/N[(s,a)]
    return q
end

function mcts_rollout!(Ļ::MCTSPar, s0, rolloutnum = 1, finishedsims = 0, initiatedsims = 0, m1 = Ļ.M, m2 = 1)
    #once all simulation tasks are completed, end rollout
    # (unfinishedsims == 0) && return nothing
    (finishedsims == Ļ.m) && return nothing

    
    (U, F) = (Ļ.U, Ļ.F)

    # println("$finishedsims simulations have been completed.  $(count(a -> isnothing(a) || istaskdone(a), F)) simulators are idle")
    
    #only do a new rollout if there are simulations left to queue up
    if initiatedsims < Ļ.m
        #m1 and m2 represent the index of the search tree previously selected and previously updated with backpropagation respectively
        treeindex = f_sel(Ļ, m1, m2)
        
        #starting from s0 recursively traverse tree using exploration function until reaching a state which has never been visited before
        #also update the ongoing simulation count for every (s,a) pair visited
        (s, traj) = node_selection!(Ļ, s0, rolloutnum, treeindex)
        
        #this will result in a crash if no element in F is nothing.  this situation should not happen though because if all simulators are occupied then the rollout will not proceed until one is freed
        selectedsim = findfirst(isnothing, F)
        
        #begin a simulation task and store the future result in F
        F[selectedsim] = @tspawnat (selectedsim + 1) (U(s), treeindex, traj) 
        initiatedsims += 1
        rolloutnum += 1
    else
        treeindex = m1
    end
    
    #check to see if any simulators are unoccupied
    if mapreduce(isnothing, (a,b) -> a || b, F) && (initiatedsims < Ļ.m)
        #if there are still unoccupied simulators and still simulations to initiate, then restart the procedure updated the selected tree index
        mcts_rollout!(Ļ, s0, rolloutnum, finishedsims, initiatedsims, treeindex, m2)
    else 
        #otherwise, wait for a result and complete backpropagation and tree sync
        getsim() = findfirst(a -> !isnothing(a) && istaskdone(a), F)
        while isnothing(getsim())
        end
        fetchindex = getsim()
        
        (qterm, simtree, simtraj) = fetch(F[fetchindex]) 
        
        backprop!(Ļ, simtree, simtraj, qterm)

        #after finishing backprop, reset this simulator to idle
        F[fetchindex] = nothing
        finishedsims += 1
        (finishedsims % calc_Ļ_syn(Ļ) == 0) && synctrees!(Ļ)

        mcts_rollout!(Ļ, s0, rolloutnum, finishedsims, initiatedsims, treeindex, simtree)
    end
end

function resetN!(Ļ::MCTSPar{BU_UCT}, N, trajectory)
    if length(trajectory) >= 2
        (s,a,r) = trajectory[end-1]
        N[(s,a)] = 1
    end
    return nothing
end

resetN!(Ļ, N, trajectory) = return nothing

@tailrec function node_selection!(Ļ::MCTSPar, s, n, m, d=Ļ.d, trajectory = [])
#this should return a node to expand by recursively traversing tree from root and the (s,a) trajectory taken
    if d ā¤ 0
        return s, trajectory
    end
    š«, N, O, O_bar, Q, c = Ļ.š«, Ļ.N[m], Ļ.O[m], Ļ.O_bar[m], Ļ.Q[m], Ļ.c
    š, TR = š«.š, š«.TR
    if !haskey(N, (s, first(š)))
    #in this case we've reached a new state in the tree
        for a in š
            N[(s,a)] = 0
            Q[(s,a)] = 0.0
            O[(s,a)] = 0
            O_bar[(s,a)] = 0
        end
        #for BU_UCT only, this function will reset the visit count of the state 2 visits prior to the new state in order to treat all previous simulation results as 1
        resetN!(Ļ, N, trajectory)
        return s, trajectory
    end

    #if we aren't at maximum depth or a new state, then select a new action with the exploration formula
    Ns = sum(calcNĢ(Ļ, (s, a), m) for a in š)
    a = argmax(a-> calcQĢ(Ļ, (s,a), m) + c*bonus(Ļ, Ns, s, a, m), š)

    (s_new, r) = TR(s, a)

    #update the ongoing simulation count for this (s,a) pair
     O[(s,a)] += 1
     #update running average of ongoing simulation count per rollout
     O_bar[(s,a)] += ((n-1)*O_bar[(s,a)] + O[(s,a)])/n 

    #continue traversing through the tree
    node_selection!(Ļ, s_new, n, m, d - 1, push!(trajectory, (s,a,r)))
end

function explore(Ļ::MonteCarloTreeSearch, s)
    š, N, Q, c = Ļ.š«.š, Ļ.N, Ļ.Q, Ļ.c
    Ns = sum(N[(s,a)] for a in š)
    return argmax(a->Q[(s,a)] + c*bonus(N[(s,a)], Ns), š)
end

function bonus(Ļ::MCTSPar, Ns, s, a, m)
    d = calcNĢ(Ļ, (s, a), m)
    d == 0 ? Inf : sqrt(2*log(Ns) / d)
end

bonus(Nsa, Ns) = Nsa == 0 ? Inf : sqrt(log(Ns)/Nsa)

@tailrec function backprop!(Ļ::MCTSPar, m, traj, v_next, i = length(traj))
    (i == 0) && return nothing
    (š«, N, Q, O, R) = (Ļ.š«, Ļ.N[m], Ļ.Q[m], Ļ.O[m], Ļ.R[m])
    Ī³ = š«.Ī³
    
    #get the action value pairs starting at the end of the trajectory
    (s,a,r) = traj[i]

    #update visit and simulation counts
    O[(s,a)] -= 1
    N[(s,a)] += 1
    n = N[(s,a)]

    #calculate discounted reward starting from the simluation value estimate
    v = r + Ī³*v_next

    #update stored statistics for tree sync
    if haskey(R, (s,a))
        push!(R[(s,a)], (v_next, 0))
    else 
        R[(s,a)] = [(v_next, 0)]
    end

    #update Q values
    Q[(s,a)] = Q[(s,a)]*((n - 1)/n) + (v / n)
    
    #proceed to the previous spot on the trajectory
    backprop!(Ļ, m, traj, v, i-1)
end

#for any algo where the tree sync interval is 1, it is effectively the same as only having one search tree, so syncing is not necessary
function synctrees!(Ļ::MCTSPar{T}) where T <: Union{UCT, TreeP, WU_UCT, VL_UCT_hard, VL_UCT_soft, BU_UCT}
    return Ļ.Q[1]
end

function synctrees!(Ļ)
    O = reduce(combine_dicts(+), Ļ.O)
    replace_dicts!(Ļ.O, O)
    O_bar = reduce(combine_dicts(+), Ļ.O_bar)
    replace_dicts!(Ļ.O_bar, O_bar)

    #only select elements from the first tree that have been previously synchronized
    R = Dict(k => filter(a -> a[2] == 1, Ļ.R[1][k]) for k in keys(Ļ.R[1]))

    for Ri in Ļ.R
        for k in keys(Ri)
            for (r, psi) in Ri[k] 
                if psi == 0
                    if haskey(R, k)
                        push!(R[k], (r, 1))
                    else
                        R[k] = [(r, 1)]
                    end
                end
            end
        end
    end

    #i think this is necessary to update the synchronization indicator but it isn't listed in the appendix
    replace_dicts!(Ļ.R, R)

    Q = Dict(k => sum(v for (v, psi) in R[k])/length(R[k]) for k in keys(R))
    N = Dict(k => length(R[k]) for k in keys(R))

    replace_dicts!(Ļ.Q, Q)
    replace_dicts!(Ļ.N, N)
    return Q
end 

function combine_dicts(op::Function, d1::T, d2::T) where T <: Dict
   dout = T() 
   klist = union(keys(d1), keys(d2))
   for k in klist 
        if haskey(d1, k) && haskey(d2, k)
            dout[k] = op(d1[k], d2[k])
        elseif haskey(d1, k)
            dout[k] = d1[k]
        else # elseif(haskey(d2, k))
            dout[k] = d2[k]
        end
   end
   return dout
end

combine_dicts(op::Function) = (d1,d2) -> combine_dicts(op, d1, d2)

function replace_dicts!(dlist::Vector{T}, dnew::T) where T <: Dict
    for i in eachindex(dlist)
        dlist[i] = dnew
    end
end

function clear_dicts!(Ļ::MCTSPar)
    for dlist in (Ļ.N, Ļ.Q, Ļ.O, Ļ.O_bar, Ļ.R)
        for i in eachindex(dlist)
            dlist[i] = typeof(dlist[i])()
        end
    end 
end

end # module
