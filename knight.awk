# Knight in AWK.
#
# As AWK is not really intended for scripting, there's numerous changes I've
# made to make things simpler/easier to read:
#
# (1) Variables
# All variables are global, unless they're explicitly declared in a function's
# parameter list; functions also can take any amount of arguments just fine. So
# to help distinguish which variables are intended to be what, all globals
# are in `UPPER_CASE`, all expected parameters are `lower_case`, and all local
# variables (which are parameters, but aren't supposed to be passed in) are 
# in `_lower_case` (ie with an `_` prefixed)

# Prints a message and then exits.
function die(msg) { print msg; exit 1 }

# Used internally to indicate a bug has occurred.
function bug(msg) { die("bug: " msg) }

# Parse command line parameters
BEGIN {
	FS="\x01" # Any non-valid field sep
	if (ARGC != 3 || (ARGV[1] != "-e" && ARGV[1] != "-f")) {
		# note there's no portable way to get script name, as `ARGV[0]` might be
		# `/usr/bin/awk`...
		die("usage: knight.awk (-e 'expr' | -f file)")
	}

	if (ARGV[1] == "-e")
		SOURCE_CODE = ARGV[2]
	else {
		oldrs=RS;RS="\1" # Knight programs can't contain `\1`
		getline SOURCE_CODE < ARGV[2]
		RS=oldrs
	}

	delete ARGV
	exit 0
}

# Execute source code.
END {
	srand()
	ARRAYS["a0"] = 0
	for (n = 0; n < 256; n++) ORD[sprintf("%c", n)] = n # Lookup table for ASCII
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
	if (value == "N") return ""
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
	if (match(value, /^[sn][[:space:]]*[-+]?[0-9]*/))
		return int(substr(value, 2, RLENGTH))
	if (value ~ /^[FNT]$/) return value == "T"
	if (value ~ /^a/) return ARRAYS[value]

	bug("bad input for 'to_num': '" value "'")
}

function to_bool(value) {
	return value !~ /^(s|[na]0|[FN])$/
}

function to_ary(value, _i, _sign) {
	delete ARY

	if (value ~ /^[FN]/) {
		# do nothing, array is empty
	} else if (value == "T")
		ARY[1] = value
	else if (value ~ /^a/)
		while (length(ARY) < ARRAYS[value])
			ARY[length(ARY) + 1] = ARRAYS[value, length(ARY) + 1]
	else if (value ~ /^s/)
		for (_i = 2; _i <= length(value); ++_i)
			ARY[_i - 1] = "s" substr(value, _i, 1)
	else if (value ~ /^n/) {
		value = int(substr(value, 2))
		value *= _sign = value < 0 ? -1 : 1
		# Sadly, `split(x, y, "")` is not valid... otherwise this would be nice.
		for (_i = 1; _i <= length(value); ++_i)
			ARY[_i] = "n" (_sign * substr(value, _i, 1))
	} else
		bug("bad input for 'to_ary': '" value "'")
}

function dump(value, _i) {
	if (value ~ /^(n|[TF])/) printf "%s", to_str(value)
	else if (value == "N") printf "null"
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
	while (sub(/^[[:space:]\n():]+|^\#[^\n]*\n?/, "")) {
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
	else if (match($0, /^([_[:upper:]]+|[-$+*\/%^<>?&|!;=~,\[\]])/)) _token = "f" substr($0, 1, 1) # ignore everything but first char for funcs
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

function generate_ast(_token, _arity, _i, _tmp) {
	# if there's nothing left, return
	if ((_token = next_token()) == "") return
	if (_token !~ /^f/) return _token

	_arity = arity(_token)
	for (_i = 1; _i <= _arity; ++_i) {
		(_tmp = generate_ast()) || die("missing argument " _i " for function '" substr(_token, 2, 1) "'")
		_token = _token FS _tmp
	}

	ASTS[_tmp = length(ASTS) + 1] = _token
	return _tmp
}

function eval_kn(source_code, _tmp) {
	$0 = source_code
	(_tmp = generate_ast()) || die("no program given")
	return run(_tmp)
}

function eql(lhs, rhs, _key) {
	if (lhs == rhs) return 1
	if (lhs !~ /^a/ || rhs !~ /^a/) return lhs == rhs
	if (ARRAYS[lhs] != ARRAYS[rhs]) return 0
	for (_key in lhs) if (!eql(lhs[_key], rhs[_key])) return 0
	return 1
}

function cmp(lhs, rhs, _min, _i, _tmp) {
	if (lhs ~ /^s/) return (lhs = substr(lhs, 2)) < (rhs = to_str(rhs)) ? -1 : lhs > rhs
	if (lhs ~ /^n/) return (lhs = int(substr(lhs, 2))) < (rhs = to_num(rhs)) ? -1 : lhs > rhs
	if (lhs ~ /^[TF]/) return cmp("n" (lhs == "T"), "n" to_bool(rhs))
	if (lhs ~ /^a/) {
		to_ary(rhs)
		_min = ARRAYS[lhs] < length(ARY) ? ARRAYS[lhs] : length(ARY)
		for (_i = 1; _i <= _min; _i++)
			if (_tmp = cmp(ARRAYS[lhs, _i], ARY[_i])) return _tmp
		return ARRAYS[lhs] < length(ARY) ? -1 : ARRAYS[lhs] > length(ARY)
	}
	bug("unknown argument to <:" lhs)
}

# print "{" value "}"
# for (a in _args) print "[" a "]=" _args[a]
function run(value, _args, _ret, _i, _tmp) {
	# If it's not something you execute, then return it.
	if (substr(value, 0, 1) == "i")
		return value in VARIABLES ? VARIABLES[value] : die("unknown variable: " value)
	if (!(ASTS[value])) 
		return value

	# Get the args and execute them
	split(ASTS[value], _args, /\x01/) # Bug in my version of awk requires using the regexp

	## Functions that don't have all operands always executed
	if (_args[1] == "fB") return _args[2]
	if (_args[1] == "f=") return VARIABLES[_args[2]] = run(_args[3])
	if (_args[1] == "f&") return to_bool(_tmp = run(_args[2])) ? run(_args[3]) : _tmp
	if (_args[1] == "f|") return to_bool(_tmp = run(_args[2])) ? _tmp : run(_args[3])
	if (_args[1] == "fW") { while (to_bool(run(_args[2]))) run(_args[3]); return "N" }
	if (_args[1] == "fI") return run(to_bool(run(_args[2])) ? _args[3] : _args[4])

	for (_tmp in _args) _args[_tmp] = run(_args[_tmp])

	# Randomly pick an integer from 0 to 0xff_ff_ff_ff
	if (_args[1] == "fR") return "n" int(rand() * 4294967295)
	if (_args[1] == "fP") {
		if (! getline _tmp) return "N"
		if (substr(_tmp, length(_tmp)) == "\r") _tmp=substr(_tmp, 1, length(_tmp) - 1)
		return "s" _tmp
	}
	if (_args[1] == "fC") return run(_args[2])
	if (_args[1] == "fE") return eval_kn(to_str(_args[2]))
	if (_args[1] == "f~") return "n" (-to_num(_args[2]))
	if (_args[1] == "f$") {
		_ret = "s"
		while (to_str(_args[2]) | getline) _ret = _ret $0 "\n" # accumulate the output.
		return _ret
	}
	if (_args[1] == "f!") return to_bool(_args[2]) ? "F" : "T"
	if (_args[1] == "fQ") exit to_num(_args[2])
	if (_args[1] == "fL") { to_ary(_args[2]); return "n" length(ARY) }
	if (_args[1] == "fD") { dump(_ret = run(_args[2])); fflush() ; return _ret }
	if (_args[1] == "fO") {
		if ((_tmp = to_str(_args[2])) ~ /\\$/) printf "%s", substr(_tmp, 1, length(_tmp) - 1)
		else print _tmp
		return "N"
	}
	if (_args[1] == "f,") { ARRAYS[_ret = new_ary(1), 1] = _args[2]; return _ret }
	if (_args[1] == "fA") {
		if (_args[2] ~ /^n/) return "s" sprintf("%c", int(substr(_args[2], 2)))
		if (_args[2] ~ /^s/) return "n" ORD[substr(_args[2], 2, 1)]
		die("unknown type to ASCII:" _args[2])
	}
	if (_args[1] == "f[") { to_ary(_args[2]); return ARY[1] }
	if (_args[1] == "f]") {
		if (_args[2] ~ /^s/) return "s" substr(_args[2], 3)
		to_ary(_args[2])
		_ret = new_ary(length(ARY) - 1)
		for (_i = 1; _i <= ARRAYS[_ret]; ++_i)
			ARRAYS[_ret, _i] = ARY[_i + 1]
		return _ret
	}
	if (_args[1] == "f;") return _args[3]
	if (_args[1] == "f+") {
		if (_args[2] ~ /^n/) return "n" (substr(_args[2], 2) + to_num(_args[3]))
		if (_args[2] ~ /^s/) return "s" (substr(_args[2], 2) to_str(_args[3]))
		if (_args[2] ~ /^a/) {
			to_ary(_args[3])
			_ret = new_ary(ARRAYS[_args[2]] + length(ARY))
			for (_i = 1; _i <= ARRAYS[_args[2]]; ++_i)
				ARRAYS[_ret, _i] = ARRAYS[_args[2], _i]
			for (; _i <= ARRAYS[_ret]; ++_i)
				ARRAYS[_ret, _i] = ARY[_i - ARRAYS[_args[2]]]
			return _ret
		}
		die("unknown type to +:" _args[2])
	}
	if (_args[1] == "f-") return "n" (substr(_args[2], 2) - to_num(_args[3]))
	if (_args[1] == "f*") {
		if (_args[2] ~ /^n/) return "n" (substr(_args[2], 2) * to_num(_args[3]))
		if (_args[2] ~ /^s/) {
			_ret = "s"
			_i = to_num(_args[3])
			while (_i--) _ret = _ret substr(_args[2], 2)
			return _ret
		}
		if (_args[2] ~ /^a/) {
			_ret = new_ary(ARRAYS[_args[2]] * to_num(_args[3]))
			for (_i = 1; _i <= ARRAYS[_ret]; ++_i)
				ARRAYS[_ret, _i] = ARRAYS[_args[2], (_i - 1) % ARRAYS[_args[2]] + 1]
			return _ret
		}
		die("unknown type to *:" _args[2])
	}
	if (_args[1] == "f/") return "n" int(substr(_args[2], 2) / to_num(_args[3]))
	if (_args[1] == "f%") return "n" (substr(_args[2], 2) % to_num(_args[3]))
	if (_args[1] == "f^") {
		if (_args[2] ~ /^n/) return "n" (substr(_args[2], 2) ^ to_num(_args[3]))
		_ret = "s"
		_tmp = to_str(_args[3]) # the separator
		for (_i = 1; _i <= ARRAYS[_args[2]]; ++_i) {
			if (_i != 1) _ret = _ret _tmp
			_ret = _ret to_str(ARRAYS[_args[2], _i])
		}
		return _ret
	}
	if (_args[1] == "f?") return eql(_args[2], _args[3]) ? "T" : "F"
	if (_args[1] == "f<") return cmp(_args[2], _args[3]) < 0 ? "T" : "F"
	if (_args[1] == "f>") return cmp(_args[2], _args[3]) > 0 ? "T" : "F"
	if (_args[1] == "fG") {
		if (_args[2] ~ /^s/) return "s" substr(to_str(_args[2]), to_num(_args[3]) + 1, to_num(_args[4]))
		if (_args[2] ~ /^a/) {
			_tmp = to_num(_args[3]) # the length
			_ret = new_ary(to_num(_args[4]))
			for (_i = 1; _i <= ARRAYS[_ret]; ++_i)
				ARRAYS[_ret, _i] = ARRAYS[_args[2], _i + _tmp]
			return _ret
		}
		die("unknown type to G:" _args[2])
	}
	if (_args[1] == "fS") {
		_args[3] = to_num(_args[3]) # _args[3] is start
		_args[4] = to_num(_args[4]) # _args[4] is len

		if (_args[2] ~ /^s/)
			return "s" (substr(_args[2], 2, _args[3]) \
			           to_str(_args[5]) \
			           substr(_args[2], 2 + _args[3] + _args[4]))
		if (_args[2] !~ /^a/) die("unknown type to S:" _args[2])

		to_ary(_args[5]) # _args[5] is replacement
		_ret = new_ary(ARRAYS[_args[2]] - _args[4] + length(ARY))
		for (_i = 1; _i <= _args[3]; ++_i)
			ARRAYS[_ret, _i] = ARRAYS[_args[2], _i]
		for (_tmp = 1; _tmp <= length(ARY); ++_tmp)
			ARRAYS[_ret, _i++] = ARY[_tmp]
		for (_tmp = _args[3] + _args[4] + 1; _tmp <= ARRAYS[_args[2]]; ++_tmp)
			ARRAYS[_ret, _i++] = ARRAYS[_args[2], _tmp]
		return _ret
	}

	bug("unknown function to evaluate: '" _args[1] "'")
}
