from qiskit import transpile, QuantumCircuit
from qiskit_aer import AerSimulator

"""EXPLANATION: 

i decided NOT to use an implementation that uses marked states, as that wouldnt be a SAT solver if you have to know the solution beforehand
my implementation can take any formula in CNF (technically should be able to) without any further marked states
and implement grovers to get the solutions (with high probability)


i am working along to this:
https://cnot.io/quantum_algorithms/grover/grovers_algorithm.html
https://cnot.io/quantum_algorithms/grover/using_grovers_algorithm.html
They are both full of logical errors (some things are randomly inversed, like what the definition of satisfiability is)
but after working trough it a lot and comparing to the lecture notes, i think i figured out a correct implementation

as well as how to build disjunctions and conjunctions from the lecture notes.

I have restricted the formula to CNF 
This means you need to do tseitins... linear time and quadratic size increase of formula

INSTRUCTION:
You only need to change line 77,78,79 to change inputs


The implementation is left basic, i did not build it modular, but simply wrote everything top to bottom 
and manually change line 77 if you want to use a different formula

BUILD MORE FORMULAS:
If you want to create your own formulas, here is the syntax:
an array, where each element corresponds to a clause 
each clause is itself an array of length = (number of variables)
this is important, a clause has an entry for each variable. 
The variable either appears positively(1), negated (-1) or not at all (0) OR both positively and negated (2) (tautology clause)
for example if we have the variables x1, x2, x3 then the clause (x1 or x3) = (1,0,1) where the 0 means that x2 does not appear in the clause
and clause (x2 or not x2) = (0,2,0) and clause (x2 or not x3) = (0,1,-1)
in total, the formula ((x1 or x3) and (x2 or not x2) and (x2 or not x3)) = [(1,0,1),(0,2,0),(0,1,-1)]
This should tell you enough about how to create your own formulas

Explaining the construction of the circuit:
We need (numberOfVariables + numberOfClauses + 1) Qubits for this construction
start with output qubit in state "-" (not sure why)
oracle:
every clause is a toffoli gate with control- and anti-control-inputs (anti is done with an X before and after the control) to the corresponding clause qubit
reasoning: since each clause rules out ont combination of variables, we can flip a clause qubit if our clause is unsat. 
for that we use anti-control if the variable appears positively and control if it appears negatively
then we end up with a CCNOT from all clause qubits to the output qubit, and do all the toffolis again in reverse order (i dont know why)
add the diffuser, measure, done
"""


#lets start with very easy forumla: (p or q), n =2, t =1 
#This results in: {'00': 1000} which means i encoded (not p and not q) (the inverse of the formula, i found the only solution that DOES NOT satisfy this)
easyTestFormula = [(1,1)]

#more difficult test formula
testFormula = [(1,1,1)] #this SHOULD encode (x1 or x2 or x3) 
#result for T=odd: 000 with around 75-80% (interesting and wrong)
# result for T=even: superposition 

#formula1 is the tautology from the slides
#FORMULA1: p ∧ (p → q) → q
#FORMULA1 in CNF: ((p or not p or q) and (q or not q or p))
formula1 = [(2,1), (1,2)]
#result for T=even: superposition (yay correct, this is a tautology)

#formula3 is the satisfiable formula from the slides
#(not p or q) and (q implies not r and not q) and (p or r)
#CNF: (not p or q) and (not r or not q) and (not p or not q) and (p or r)
#n=3
formula3 = [(-1,1,0),(0,-1,-1),(-1,-1,0),(1,0,1)]
#results for T=1: 001 is most likely (75%). This is correct, formula 3 is SAT and the only solution is 001 (p=0, q=0, r=1)
#results for T=2: full superposition (expected, T=1 is the correct T here as there is only 1 solution)


#HERE is where you define which formula is used. This is the only lines you need to change to use this script
clauses = formula3
T = 11  # and define T (number of iterations)
n = 3  # number of variables OVERALL (for formula1, set to 2, for formula3, set to 3)

#here i could add syntax check

input = n
auxQubits = len(clauses)+1 #number of Clauses + output bit
totalQubits = input + auxQubits


#this creates the quantum circuit with the correct size. Here we need n (#var) qubits + numberClauses+1 classical bits, 
# at the end add #var classical bits for measuring
circ = QuantumCircuit(totalQubits, input)


#add a Hadamard gate to the first n qubits (initialize superposition)
circ.h(range(0,n))

#initialize the output qubit to "-" (H and Z)
circ.h(totalQubits-1)
circ.z(totalQubits-1)

for i in range(T):
    #for each clause, build the clause and map it to a qubit for each clause
    #(this is what is explained in the lecture notes. Each clause is a disjunction, and here we build that for all clauses)
    i=0
    for clause in clauses:
        con = []
        j=0
        for var in clause:
            if var == -1: #case: variable appears negated
                con.append(j)
            if var == 0: #case variable does not appear in clause
                var = var #do nothing
            if var == 1: #case variable appears normally
                circ.x(j)
                con.append(j)
            if var == 2: #case variable appears normally AND negated. This means clause is always true, does not exlaude anything. dont do anything
                var = var #TODO
            j=j+1
        circ.mcx(con, input+i) #do the big toffoli with the correct qubits. This is what gets added for each clause
        #now apply the X that is applied if var==1 again. That was only needed for anti-control and needs to be undone before going to the next clause
        j=0
        for var in clause:
            if var == 1:
                circ.x(j)
            j=j+1
        i = i+1



    #After adding the disjunction for each clause to the clause qubit (n+#clause)
    #now we need a toffoli over all clause qubits to the output qubit
    #this is the checker circuit that only acts if ALL clauses are satisfied
    for i in range(len(clauses)):
        circ.x(n+i)
    con = []
    for i in range(len(clauses)):
        con.append(n+i)
    circ.mcx(con,totalQubits-1)
    for i in range(len(clauses)):
        circ.x(n+i)

    #now we need to reverse all the clause toffoli gates. I am not sure why this is done or necessary, but i tried with and without and this seems correct
    i=len(clauses)-1
    for clause in reversed(clauses): #go trough the clauses in reverse order and do the same as before
        con = []
        j=0
        for var in clause:
            if var == -1: #case: variable appears negated
                con.append(j)
            if var == 0: #case variable does not appear in clause
                var = var #do nothing
            if var == 1: #case variable appears normally
                circ.x(j)
                con.append(j)
            if var == 2: #case variable appears normally AND negated
                var = var #TODO
            j=j+1
        circ.mcx(con, input+i) #do the big toffoli with the correct qubits. This is what gets added for each clause
        j=0
        for var in clause:
            if var == 1:
                circ.x(j)
            j=j+1
        i = i-1



    

#START DIFFUSER:
#build the first part of the diffuser (H and X on all input qubits)
circ.h(range(0,n))
circ.x(range(0,n))

#diffuser CCNOT 
con = []
for i in range (n):
    con.append((i))
circ.mcx(con, totalQubits-1)

#build the second part of the diffuser (X and H on all input qubits)
circ.x(range(0,n))
circ.h(range(0,n))
#END DIFFUSER

#measure the first n qubits
con=[]
for i in range(n):
    con.append(i)
circ.measure(con,reversed(con))

#this would measure the output qubit if you want to check for 1- would also need to increase number of classical bits by 1 in circ=QuantumCircuit...
#circ.measure(totalQubits-1, input)


#print out circuit for debugging purposes and because it looks so nice
print(circ)

shots = 1000
#simulate:
simulator = AerSimulator() 
circuit = transpile(circ, simulator)
result = simulator.run(circ, shots=shots).result()
dist = result.get_counts(circ)
print(dist)