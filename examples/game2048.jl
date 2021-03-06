using Game2048
using MCTSExperiments

board = initbboard()

function update_state(board::Game2048.Bitboard, action)
    (new_board, reward) = move_reward(board, action)
    if new_board != board
        new_board = add_tile(new_board)
    end
    return (new_board, reward)
end

function update_state(board::Game2048.Bitboard, policy::Function)
    action = policy(board)
    (new_board, reward) = move_reward(board, action)
    if new_board != board
        new_board = add_tile(new_board)
    end
    return (new_board, reward)
end

#function that returns an action given the board state
function random_2048_policy(board::Game2048.Bitboard)
    rand([up, down, left, right])
end

#policy that randomly selects either left or right
function horizontal_2048_policy(board::Game2048.Bitboard)
    rand([left, right])
end


function rollout_game(board::Game2048.Bitboard, policy::Function; depth::Int64 = 10)
    boardhistory = Vector{Game2048.Bitboard}(undef, depth+1)
    rewardhistory = zeros(Int32, depth+1)
    boardhistory[1] = board
    for i in 2:depth
        (boardhistory[i], rewardhistory[i]) = update_state(boardhistory[i-1], policy)
    end
    return boardhistory, rewardhistory
end

#generates a vector of board states, using horizontal only strategy because I'm not sure how to get the correct reward function for up/down moves, see fork of Game2048 package
horizontal_game_history = rollout_game(board, horizontal_2048_policy, depth = 10)

println("Final random state after 10 moves has a total reward of $(sum(horizontal_game_history[2])) and a final board state of:")
display(horizontal_game_history[1][end])

#note that the bitboard stores log2 of the value at each tile so 1 => 2^1 = 2, 3 => 2^3 = 8

##try to apply the MDP datatype and the greedy lookahead rollout evaluation
#define the Game2048 problem as an MDP, is the state space supposed to just represent the state of the game and the possible transition states at a particular moment in time?
Game2048MDP = (
    0.5, #discount factor
    nothing, #how to represent state space?   Can it simply be a function that samples from the state space?
    [left, right], #action space, restrict to left/right for now 
    nothing, #transition function should represent from a given board state the probability of every possible new board state given each action.  Here the stochastic nature of the problem comes from the new random tiles being added
    (s, a) -> move_reward(s, a)[2], #reward function returns the reward for a state action pair
    update_state #transition reward function that returns an updated state/reward pair given a state/action input
)


#what is needed in the MDP to just do the greedy rollout from the start of chapter 9?
Game2048Rollout = (
    Game2048MDP, #problem
    horizontal_2048_policy, #rollout policy
    10 #depth
)

#=
want to run the following

Game2048Rollout(starting_board)

which will call the following:  U(s) = rollout(??.????, s, ??.??, ??.d)
and the rollout function runs the following: 
function rollout(????, s, ??, d)
    ret = 0.0
    for t in 1:d
        a = ??(s)
        s, r = randstep(????, s, a)
        ret += ????.??^(t-1) * r
    end
    return ret
end

and randstep(????::MDP, s, a) = ????.TR(s, a)

finally what is returned is greedy(??.????, U, s).a which calls
u, a = findmax(a->lookahead(????, U, s, a), ????.????) which calls
function lookahead(????::MDP, U, s, a)
    ????, T, R, ?? = ????.????, ????.T, ????.R, ????.??
    return R(s,a) + ??*sum(T(s,a,s???)*U(s???) for s??? in ????)
end

so every single field is required in the MDP struct and it seems like it should be built from scratch for a given starting state as the rollout is only done from a particular starting state.

=#
