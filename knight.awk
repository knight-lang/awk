# Knight in awk.
# Note: UPPER_CASE variables are global, lower_case are parameters to
# functions, and _underscore are local variables to functions.

# Prints a message and then exits.
function die(msg) { print msg; exit 1 }

# Used internally to indicate a bug has occured.
function bug(msg) { die("bug: " msg) }

# Parse command line parameters
BEGIN {
	FS="\x01" # Any non-valid field sep
	FS="@" # Any non-valid field sep
	if (ARGC != 3 || (ARGV[1] != "-e" && ARGV[1] != "-f")) {
		# note there's no portable way to get script name, as `ARGV[0]` might be
		# `/usr/bin/awk`...
		die("usage: knight.awk (-e 'expr' | -f file)")
	}

	if (ARGV[1] == "-e") {
		SOURCE_CODE = ARGV[2]
		delete ARGV # just remove the entire argv.
		exit 0 # Don't execute the `{ SOURCE_CODE = ... }` patterns.
	} else
		delete ARGV[1] # but retain ARGV[2], as we'll read from that.
}
# Collect source code.
{ SOURCE_CODE = SOURCE_CODE "\n" $0 }

# Execute source code.
END {
	srand()
	ARRAYS["a0"] = 0
	eval_kn(SOURCE_CODE)
}

# Values are stored as:
# - `i...` the variable `...`
# - `s...` the string `...`
# - `n...` the number `...`
# - `T` / `F` / `N` for those literals
# - `aNUM`; `ARRAYS[value]` is the length, and `ARRAYS[value, N]` is the values
# - `fC{FS<arg>}`; function, <arg>s are AST nodes.
function to_str(value, _acc, _i) {
	if (value ~ /^[sn]/) return substr(value, 2)
	if (value == "T") return "true"
	if (value == "F") return "false"
	if (value == "N") return "null"
	if (value ~ /^a/) {
		_acc = ""
		for (_i = 1; _i <= ARRAYS[value]; ++_i)
			_acc = _acc (_i == 1 ? "" : "\n") to_str(ARRAYS[value, _i], 1)
		return _acc
	}

	bug("bad input for 'to_str': '" value "'")
}

function to_num(value) {
	# Note we make sure `s<non-digit>` matches here.
	if (match(value, /^[sn][[:blank:]]*[-+]?[0-9]*/))
		return int(substr(value, 2, RLENGTH))
	if (value ~ /^[FNT]$/) return value == "T"
	if (value ~ /^a/) return ARRAYS[value]

	bug("bad input for 'to_num': '" value "'")
}

function to_bool(value) {
	return value !~ /^(s|[na]0|[FN])$/
}

function to_ary(value, _tmp, _sign) {
	delete ARY

	if (value ~ /^[FN]/) {
		# do nothing, array is empty
	} else if (value == "T")
		ARY[1] = value
	else if (value ~ /^a/)
		while (length(ARY) < ARRAYS[value])
			ARY[length(ARY) + 1] = ARRAYS[value, length(ARY) + 1]
	else if (value ~ /^s/) {
		split(substr(value, 2), ARY, "")
		for (_tmp in ARY) ARY[_tmp] = "s" ARY[_tmp]
	} else if (value ~ /^n/) {
		value = int(substr(value, 2))
		_sign = value < 0 ? -1 : 1
		value *= _sign
		split(value, ARY, "")
		for (_tmp in ARY) ARY[_tmp] = "n" (_sign * int(ARY[_tmp]))
	} else
		bug("bad input for 'to_ary': '" value "'")
}

function dump(value, _i) {
	if (value ~ /^(n|[TFN])/)
		printf "%s", to_str(value)
	else if (value ~ /^s/) {
		value = substr(value, 2)
		gsub(/\\/, "\\\\", value)
		gsub(/\n/, "\\n", value)
		gsub(/\r/, "\\r", value)
		gsub(/\t/, "\\t", value)
		gsub(/"/, "\\\"", value)
		printf "\"%s\"", value
	} else if (value ~ /^a/) {
		printf "["
		for (_i = 1; _i <= ARRAYS[value]; ++_i) {
			if (_i != 1) printf ", "
			dump(ARRAYS[value, _i])
		}
		printf "]"
	} else
		bug("unknown value to dump '" value "'")
}

function new_ary(len, _idx) {
	ARRAYS[_idx = "a" length(ARRAYS)] = len
	return _idx
}

function next_token(_token) {
	# Strip out all leading whitespace and comments
	while (sub(/^[[:blank:]\n():]+|^\#[^\n]*\n?/, "")) {
		# do nothing
	}

	# If `$0`'s empty, then return.
	if (!length()) return

	# note the ordering of these is important, eg `i` comes before `n`, or `f` after `i`
	if (match($0, /^[0-9]+/)) _token = "n" substr($0, 1, RLENGTH)
	else if (match($0, /^[_[:lower:][:digit:]]+/)) _token = "i" substr($0, 1, RLENGTH)
	else if (match($0, /^("[^"]*"|'[^']*')/)) _token = "s" substr($0, 2, RLENGTH - 2) # strip out the quotes
	else if (match($0, /^@/)) _token = "a0" # empty array
	else if (match($0, /^[TFN][_[:upper:]]*/)) _token = substr($0, 1, 1) # ignore everything but first char for funcs
	else if (match($0, /^([_[:upper:]]+|[-`+*\/%^<>?&|!;=~,\[\]])/)) _token = "f" substr($0, 1, 1) # ignore everything but first char for funcs
	else die("unknown token start '" substr($0, 1, 1) "'")

	$0 = substr($0, RLENGTH + 1)
	return _token
}

# Gets the arity of the token, ie how many arguments it takes.
function arity(token) {
	if (token ~ /^([^f]|f[PR])/) return 0
	if (token ~ /^f[`OEBCQ!LD,A\[\]~]/) return 1
	if (token ~ /^f[-+*\/%^?<>&|;=W]/) return 2
	if (token ~ /^f[GI]/) return 3
	if (token == "fS") return 4
	bug("cant get arity for token '" token "'")
}

function generate_ast(_token, _arity, _tmp, _tmp2) {
	# if there's nothing left, return
	if ((_token = next_token()) == "") return
	if (_token !~ /^f/) return _token

	_arity = arity(_token)
	for (_tmp = 1; _tmp <= _arity; ++_tmp) {
		(_tmp2 = generate_ast()) || die("missing argument " _tmp " for function '" substr(_token, 2, 1) "'")
		_token = _token FS _tmp2
	}

	ASTS[_tmp = length(ASTS) + 1] = _token
	return _tmp
}

function eval_kn(source_code, _tmp) {
	$0 = source_code
	(_tmp = generate_ast()) || die("no program given")
	return run(_tmp)
}

# print "{" value "}"
# for (a in _args) print "[" a "]=" _args[a]
function run(value, _args, _tmp, _tmp2) {
	# If it's not something you execute, then return it.
	if (substr(value, 0, 1) == "i")
		return value in VARIABLES ? VARIABLES[value] : die("unknown variable: " value)
	if (!(ASTS[value])) 
		return value

	# Get the args and execute them
	# This will run the first argument, `f<FN>`, but since that's not in ASTS, it's returned
	split(ASTS[value], _args)

	## Functions that don't have all operands always executed
	if (_args[1] == "fB") return _args[2]
	if (_args[1] == "f=") return VARIABLES[_args[2]] = run(_args[3])
	if (_args[1] == "f&") return to_bool(_tmp = run(_args[2])) ? run(_args[3]) : _tmp
	if (_args[1] == "f|") return to_bool(_tmp = run(_args[2])) ? _tmp : run(_args[3])
	if (_args[1] == "fW") { while (to_bool(_args[2])) run(_args[3]); return "N" }
	if (_args[1] == "fI") return run(to_bool(_args[2]) ? _args[3] : _args[4])

	for (_tmp in _args) _args[_tmp] = run(_args[_tmp])
	# for (a in _args) print "[" a "]=" _args[a]

	# Randomly pick an integer from 0 to 0xff_ff_ff_ff
	if (_args[1] == "fR") return "n" int(rand() * 4294967295)
	if (_args[1] == "fP") { getline _tmp; return "s" _tmp }
	if (_args[1] == "fC") return run(_args[2])
	if (_args[1] == "fE") return eval_kn(to_str(_args[2]))
	if (_args[1] == "f~") return "n" (-to_num(_args[2]))
	if (_args[1] == "f`") {
		_tmp = "s"
		while (to_str(_args[2]) | getline) _tmp = _tmp $0 "\n" # accumulate the output.
		return _tmp
	}
	if (_args[1] == "f!") return to_bool(_args[2]) ? "F" : "T"
	if (_args[1] == "fQ") exit to_num(_args[2])
	if (_args[1] == "fL") { to_ary(_args[2]); return "n" length(ARY) }
	if (_args[1] == "fD") { dump(_tmp = run(_args[2])); return _tmp }
	if (_args[1] == "fO") {
		if ((_tmp = to_str(_args[2])) ~ /\\$/) printf "%s", substr(_tmp, 1, length(_tmp) - 1)
		else print _tmp
	}
	if (_args[1] == "f,") { ARRAYS[_tmp = new_ary(1), 1] = _args[2]; return _tmp }
	if (_args[1] == "fA")
		return _args[2] ~ /^n/ ? "s" sprintf("%c", substr(_args[2], 1)) : \
			die("Todo") # n" sprintf("%d", "'" substr(_args[2], 1))
	if (_args[1] == "f[") { to_ary(_args[2]); return ARY[1] }
	if (_args[1] == "f]") {
		to_ary(_args[2])
		_tmp = new_ary(length(ARY) - 1)
		for (_tmp2 = 1; _tmp2 < ARRAYS[_tmp]; ++_tmp2)
			ARRAYS[_tmp, _tmp2] = ARY[_tmp2 + 1]
		return _tmp
	}
	if (_args[1] == "f;") return _args[3]
	if (_args[1] == "f+") die("todo")
	if (_args[1] == "f-") die("todo")
	if (_args[1] == "f*") die("todo")
	# 	if (_args[2] ~ /^a/) {
	# 		_tmp2 = to_num(_args[3])
	# 		_tmp = new_ary(ARRAYS[_args[2]] * (_args[3] = to_num))
	# 	}
	# }die("todo")
	if (_args[1] == "f/") die("todo")
	if (_args[1] == "f%") die("todo")
	if (_args[1] == "f^") die("todo")
	if (_args[1] == "f?") die("todo")
	if (_args[1] == "f<") die("todo")
	if (_args[1] == "f>") die("todo")
	if (_args[1] == "fG") die("todo")
	if (_args[1] == "fS") die("todo")

	bug("unknown function to evaluate: '" _args[1] "'")
}
