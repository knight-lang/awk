# Prints a message and then exits.
function die(msg) { print msg; exit 1 }

# Used internally to indicate a bug has occured.
function bug(msg) { die("bug: " msg) }

# Parse command line parameters
BEGIN {
	if (ARGC != 3 || (ARGV[1] != "-e" && ARGV[1] != "-f")) {
		# note there's no portable way to get script name, as `ARGV[0]` might be
		# `/usr/bin/awk`...
		die("usage: knight.awk (-e 'expr' | -f file)")
	}

	if (ARGV[1] == "-e") {
		source_code = ARGV[2]
		delete ARGV # just remove the entire argv.
		exit 0 # Don't execute the `{ source_code = ... }` patterns.
	} else
		delete ARGV[1] # but retain ARGV[2], as we'll read from that.
}

# Collect source code.
{ source_code = source_code "\n" $0 }

# Execute source code.
END {
	$0 = source_code
	srand()

	(ast_value = generate_ast()) || die("no program given")
	run(ast_value)
}


# NOTE: awk starts indexing at 1

# Fetch the next token from `$0`, updating `$0` in the process. Returns a falsey
# value if the stream is empty, and `die`s if an invalid character is
# encountered.
function next_token() {
	# Strip out all leading whitespace and comments
	while (sub(/^([[:blank:]\n():]+|\#[^\n]*)/, "")) {
		# do nothing
	}

	# If `$0`'s empty, then return.
	if (!length())
		return

	if (match($0, /^[0-9]+/))
		token = "n" substr($0, 1, RLENGTH)
	else if (match($0, /^[a-z_][a-z0-9_]*/))
		token = "i" substr($0, 1, RLENGTH)
	else if (match($0, /^("[^"]*"|'[^']*')/))
		token = "s" substr($0, 2, RLENGTH - 2) # strip out the quotes
	else if (match($0, /^@/))
		token = "a0" FS "0"
	else if (match($0, /^([A-Z][A-Z_]*|[-`+*\/%^<>?&|!;=@~,\[\]])/))
		token = "f" substr($0, 1, 1) # ignore everything but first char for funcs
	else
		die("unknown token start '" substr($0, 1, 1) "'")

	$0 = substr($0, RLENGTH + 1)
	return token
}

# Gets the arity of the token, ie how many arguments it takes.
function arity(token) {
	if (token ~ /^([^f]|f[TFNPR])/) return 0
	if (token ~ /f[`OEBCQ!LD,\[\]~]/) return 1
	if (token ~ /f[-+*\/%^?<>&|;=W]/) return 2
	if (token == "fG" || token == "fI") return 3
	if (token == "fS") return 4
	bug("cant get arity for token '" token "'")
}

# Generates an AST tree, storing values in the `ast` global variable. Returns
# the index of the node that was just generated.
# (The two parameters are simply local variables)
function generate_ast(_node_idx, token, _i) {
	# if there's nothing left, return
	if (!(token = next_token()))
		return

	ast[_node_idx = next_node_idx += 1] = token

	for(_i = 1; _i <= arity(token); ++_i) {
		if (!(ast[_node_idx, _i] = generate_ast()))
			die("missing argument " _i " for function '" substr(token, 2, 1) "'")
	}

	return _node_idx
}

# converts `input` to a string, `run`ning the value first unless `dontrun` is
# given.
function to_str(input, dontrun) {
	if (!dontrun) input = run(input)

	if (input ~ /^[sn]/) return substr(input, 2)
	if (input == "fT") return "true"
	if (input == "fF") return "false"
	if (input == "fN") return "null"
	if (input ~ /^a/) die("todo: ary to str")

	bug("bad input for 'to_str': '" input "'")
}

# converts `input` to a number, `run`ning the value first unless `dontrun` is
# given.
function to_num(input, dontrun) {
	if (!dontrun) input = run(input)

	if (match(input, /^[sn][[:blank:]]*[-+]?[0-9]*/))
		return int(substr(input, 2, RLENGTH))
	if (input == "fT") return 1
	if (input == "fF" || input == "fN") return 0
	if (input ~ /^a/) die("todo: ary to num")

	bug("bad input for 'to_num': '" input "'")
}

# converts `input` to a boolean, `run`ning the value first unless `dontrun` is
# given.
function to_bool(input, dontrun, _ary) {
	if (!dontrun) input = run(input)
	if (input ~ /^a/) {
		input = substr(input, 2)
		split(input, _ary)
		return int(_ary[2]) != 0
	}

	return input !~ /^(s|n0|f[FN])$/;
}

function newary(n, a1, a2, a3, _ret) {
	_ret = "a" (ary_next_index += 1) FS n
	if (n >= 1) arrays[ary_next_index, 1] = a1
	if (n >= 2) arrays[ary_next_index, 2] = a2
	if (n >= 3) arrays[ary_next_index, 3] = a3
	if (n >= 4) arrays[ary_next_index, 4] = a4
	return _ret
}

function to_ary(input) {
	if (input ~ /^a/) return input
	if (input == "fF" || input == "fN") return "a0" FS 0
	if (input == "fT") return newary(1, input)
	die("todo: " input)
}

function dump(value, _ary, _len) {
	if (value ~ /^n/) printf "%d", substr(value, 2)
	else if (value == "fT") printf "true"
	else if (value == "fF") printf "false"
	else if (value == "fN") printf "null"
	else if (value ~ /^s/) {
		value = substr(value, 2)
		gsub(/\\/, "\\\\", value)
		gsub(/\n/, "\\n", value)
		gsub(/\r/, "\\r", value)
		gsub(/\t/, "\\t", value)
		gsub(/"/, "\\\"", value)
		printf "%s", value
	}
	else if (value ~ /^a/) {
		value = substr(value, 2)
		split(value, _ary)
		_len = int(_ary[2])
		printf "["
		for (idx = 1 ; idx <= _len; idx+=1 ) {
			if (idx != 1) printf ", "
			dump(arrays[_ary[1], idx])
		}
		printf "]"
	}
	else if (value ~ /^[0-9]+/) printf "AstNode(%s)", ast[value]
	else bug("unknown value '" value "'")
}


# Runs the ast node for `node_idx`, returning the value that's computed.
# Note that `args` is not a parameter, but simply a local variable.
function run(node_idx, args, lhs, value) {
	if (!(token = ast[node_idx]))
		bug("token number '" node_idx "' doesn't exist in the ast")

	# return the token itself for literals
	if (token ~ /^([sna]|f[TFN])/) return token

	# if it's an identifier, evaluate it.
	if (substr(token, 1, 1) == "i") {
		if (value = env[token]) return value

		die("variable '" substr(token, 2) "' not found!")
	}

	# assign arguments
	for(i = 1; i <= arity(token); ++i)
		args[i] = ast[node_idx, i]

	# alias to make string comparisons slightly faster. 
	fn = substr(token, 2)

	# Get a new input line, store it into tmp, and then return that value.
	if (fn == "P") {
		getline tmp
		return "s" tmp
	}

	# Randomly pick an integer from 0 to 0xff_ff_ff_ff
	if (fn == "R") return "n" int(rand() * 4294967295)

	# When creating blocks, simply return the token number of the thing to eval.
	if (fn == "B") return args[1]

	# When calling a block, you need to execute the result of running `args[1]`.
	if (fn == "C") return run(run(args[1]))

	# Evaluates the first argument as Knight code, returning the result of the
	# evaluation.
	if (fn == "E") {
		$0 = to_str(args[1])
		return run(generate_ast())
	}

	# Negates its argument
	if (fn == "~") {
		return "n" (-to_num(args[1]))
	}

	# The '`' keyword's used to execute shell commands and get the stdout.
	if (fn == "`") {
		result = ""

		# accumulate the output.
		while (to_str(args[1]) | getline) result = result $0 "\n"

		return "s" result
	}

	# Logical negation. All arguments are converted to booleans first.
	if (fn == "!") return to_bool(args[1]) ? "fF" : "fT"

	# Quit exits with the status code of its argument.
	if (fn == "Q") exit to_num(args[1])

	# Gets the length of the first argument, in chars.
	if (fn == "L") {
		value = run(args[1])
		if (value ~ /^s/) return "n" length(value)
		split(to_ary(value), value)
		return "n" length(to_ary())
	}

	# Dumps a debug representation
	if (fn == "D") {
		dump(value = run(args[1]))
		return value
	}

	# Output something to stdout. If the string ends in `\`, a newline won't be
	# added. We return the evaluated argument.
	if (fn == "O") {
		str = to_str(args[1])

		if (str ~ /\\$/) printf "%s", substr(str, 1, length(str) - 1)
		else print str

		return "fN"
	}

	if (fn == ",") return newary(1, run(args[1]))

	# The `;` function simply evaluates the LHS then the RHS, returning the RHS.
	if (fn == ";") {
		run(args[1])
		return run(args[2])
	}

	# The `=` operator assigns to the global scope then return the assigned val.
	if (fn == "=") return env[ast[args[1]]] = run(args[2])

	# The `+` operator: If the first operand's a string, we do concatenation.
	# Otherwise, we do numerical addition.
	if (fn == "+") {
		lhs = run(args[1])

		if (lhs ~ /^s/) return "s" to_str(lhs, 1) to_str(args[2])
		else if (lhs ~ /^n/) return "n" (to_num(lhs, 1) + to_num(args[2]))
		else {
			# TODO: concat array
		}
	}

	# The `*` operator: repeats its arguments if its a string, otherwise we do
	# numeric multiplication
	if (fn == "*") {
		lhs = run(args[1])

		# TODO: multiply array

		if (lhs ~ /^n/) return "n" (to_num(lhs, 1) * to_num(args[2]))

		lhs = to_str(lhs, 1)
		amnt = to_num(args[2])
		result = "s"

		while (amnt--) result = result lhs

		return result
	}

	# Simple math functions
	if (fn == "-") return "n" (to_num(args[1]) -  to_num(args[2]))
	if (fn == "/") return "n" (to_num(args[1]) /  to_num(args[2])) #/
	if (fn == "%") return "n" (to_num(args[1]) %  to_num(args[2]))
	if (fn == "^") return "n" (to_num(args[1]) ** to_num(args[2]))

	# Short-circuiting logical operators.
	if (fn ~ /[&|]/) {
		lhs = run(args[1])

		return (to_bool(lhs, 1) == (fn == "&")) ? run(args[2]) : lhs
	}

	# Checks for equality without coercion.
	if (fn == "?") return run(args[1]) == run(args[2]) ? "fT" : "fF"

	# Comparison operators. We don't have to do anything fancy for string/numebrs
	# as awk already does that for us.
	if (fn == "<") {
		lhs = run(args[1])

		if (lhs ~ /^s/) less = to_str(lhs, 1) < to_str(args[2])
		else if (lhs ~ /^n/) less = to_num(lhs, 1) < to_num(args[2])
		else less = to_bool(args[2]) && lhs == "fF"

		return less ? "fT" : "fF"
	}

	if (fn == ">") {
		lhs = run(args[1])

		if (lhs ~ /^s/) more = to_str(lhs, 1) > to_str(args[2])
		else if (lhs ~ /^n/) more = to_num(lhs, 1) > to_num(args[2])
		else more = !to_bool(args[2]) && lhs == "fT"

		return more ? "fT" : "fF"
	}

	# The while function executes the body until the condition is false. The
	# return value is `null` if body never runs, otherwise it's the last returned
	# value from the body.
	if (fn == "W") {
		while (to_bool(args[1])) run(args[2])
		return "fN"
	}

	# Runs either the second or third argument, depending on the first argument.
	if (fn == "I") return run(to_bool(args[1]) ? args[2] : args[3])

	if (fn == "G")
		return "s" substr(to_str(args[1]), to_num(args[2]) + 1, to_num(args[3]))

	if (fn == "S") {
		args[1] = to_str(args[1])
		args[2] = to_num(args[2])
		args[3] = to_num(args[3])
		args[4] = to_str(args[4])

		return "s" substr(args[1], 1, args[2]) \
			args[4] substr(args[1], args[2] + args[3], length(args[1]))
	}

	bug("unknown function to evaluate '" fn "'")
}
 
