#!/bin/bash
#
# This is a utility script to create wordlists for later use by the
# OWASP ModSecurity Core Rule Set.
#
# The scripts extracts function names out of the PHP source code and
# filters them into different categories.
#

IFS=$'\n\t'

# --------------------------------------------------
# Initialization
# --------------------------------------------------

VERBOSE=0
ERROR=0

MYDATE=$(date +"%Y-%m-%d")
MYDATE_SECONDS=$(date +"%s")

AGE_LIMIT=30
FREQUENCY_LIMIT=90000

RULES="933150 933151 933161"
RULES_CMDLINE=""

PHP_REPO=""
PHP_REPO_CMDLINE=""
PHP_REPO_GITHUB="https://github.com/php/php-src"

SPELL_PATH="../fp-finder/spell.sh"
SPELL_PATH_CMDLINE=""


TMP_PHP_FUNCTIONS_FREQUENCIES=$(mktemp)
TMP_PHP_FUNCTIONS_FREQUENCIES_ERRORS=$(mktemp)
PHP_FUNCTIONS_FREQUENCIES_CMDLINE=""

TMP_PHP_FUNCTIONS=$(mktemp)
TMP_ENGLISH_WORDS=$(mktemp)
TMP_PHP_FUNCTIONS_FREQUENT=$(mktemp)
TMP_PHP_FUNCTIONS_RARE=$(mktemp)
TMPDIR=$(mktemp -d)

trap 'rm -rf $TMP_PHP_FUNCTIONS $TMP_PHP_FUNCTIONS_FREQUENCIES  $TMP_PHP_FUNCTIONS_FREQUENT $TMP_PHP_FUNCTIONS_RARE $TMP_ENGLISH_WORDS $TMPDIR' INT TERM EXIT

HIGH_RISK_FUNCTIONS_FILENAME="php-high-risk-functions.txt"

R933160_FILENAME="933160.ra"
R933161_FILENAME="933161.ra"
read -r -d '' R933161_PREFIX << 'EOF'
##! Please refer to the documentation at
##! https://coreruleset.org/docs/development/regex_assembly/.

##!+ i
##!^ \b
##!$ (?:\s|/\*.*\*/|//.*|#.*)*\(.*\)
EOF

R933150_FILENAME="php-function-names-933150.data"
R933151_FILENAME="php-function-names-933151.data"

DATA_FILE_PATH="../../rules/"
RA_FILE_PATH="../../regex-assembly/"

# --------------------------------------------------
# Library Functions
# --------------------------------------------------

function usage {

	cat << EOF

This is a utility script to create wordlists for later use by the
OWASP ModSecurity Core Rule Set.

Usage:

$> $(basename "$0") [options]

Options:

 -a  --agelimit STR           Age in days before frequency is retrieved anew from github
                              Only makes sense when used together with frequencylist
                              Default: $AGE_LIMIT
 -h  --help                   Print help text and exit.
 -f  --frequencylist STR      File with frequencies of PHP function usage on github
 -F  --frequencylimit STR     Minimum number of occurrences in GitHub repo to qualify for base rule
                              Functions not meeting this limit will be added to stricter sibling
			      Default: $FREQUENCY_LIMIT
 -p  --phprepo STR            Path to PHP repository. Optional.
 -r  --rules STR              Space separated list of rules to cover.
                              Rules available:
			      * 933150
			      * 933151
			      * 933161
			      Default: "$RULES"
 -s  --spell STR              Path of spell.sh script.
                              Default: $SPELL_PATH
 -v  --verbose                Verbose output


Filter Architecture
-------------------
See discussion at
https://github.com/coreruleset/coreruleset/pull/3228#issuecomment-1594813466

Input: Function list out of PHP source code

Filter 1: Is the function name an English word?
If yes: Add to source for rule 933161
If no: Continue
Filter 2: Is the function name frequently used on GitHub (across all PHP repos)?
If yes: Add to word list for 933150
If no: Add to word list for 933151

Please note that rules 933150 and 933151 are parallel match rules. So the
output of this script is the parallel match file for these rules.

Rule 933161 is a regular expression rule, though, so the output of this
script is the source file for the CRS toolchain.

EOF

	exit 0
}

function break_on_error {
	if [ "$1" -ne 0 ]; then
		echo
		if [ -n "$2" ]; then
			echo -e "$2"
		fi
		echo "FAILED. This is fatal. Aborting"
		exit 1
	fi
}


function get_frequency {
	NUM=""
	N=0

	until [ -n "$NUM" ] || [ $N -gt 4 ]; do
		N=$((N + 1))

		CURL_OUTPUT=$(curl -v \
			--header "X-GitHub-Api-Version: 2022-11-28" \
			--header "Accept: application/vnd.github+json" \
			--header "Authorization: Bearer $GITHUB_TOKEN" \
			"https://api.github.com/search/code?q=$1+language:php&type=Code&per_page=1" 2>&1)

		NUM=$(echo "$CURL_OUTPUT" | grep "total_count" | grep -o -E "[0-9]*")

		if [ -z "$NUM" ]; then
			>&2 echo -n "  Curl call for $1 failed."
			if [ "$(echo "$CURL_OUTPUT" | grep -c "x-ratelimit-remaining: 0")" -eq 1 ]; then
				>&2 echo -n " Hitted rate limit. Waiting..."
				# 50 is the number of seconds to wait for the rate limit to be reset to 10
				# /search/code endpoint is limited to 10 requests per minute.
				# See https://docs.github.com/en/rest/search/search?apiVersion=2022-11-28#search-code
				sleep 25
			fi
			>&2 echo " Trying again ($N)."
		fi

		sleep 1
	done
	if [ -z "$NUM" ]; then
		echo "- $1" >> "$TMP_PHP_FUNCTIONS_FREQUENCIES_ERRORS"
	fi
	echo "$NUM"
}


function vprint {

	if [ $VERBOSE -eq 1 ]; then
		echo -e "$1"
	fi
}

# --------------------------------------------------
# Parameter reading and checking
# --------------------------------------------------

while true
do
	if [ -n "${1-}" ]; then
                ARG="${1-}"
		FIRSTCHAR="$(echo "$ARG " | cut -b1)"
		# The space after $ARG makes sure CLI option "-e" (an echo option) is also accepted
                if [ "$FIRSTCHAR" == "-" ]; then
                        case $1 in
                        -h) usage; exit;;
                        --help) usage; exit;;
			-a) export AGE_LIMIT_CMDLINE="${2-}"; shift;;
			--agelimit) export AGE_LIMIT_CMDLINE="${2-}"; shift;;
			-f) export PHP_FUNCTIONS_FREQUENCIES_CMDLINE="${2-}"; shift;;
			--frequencylist) export PHP_FUNCTIONS_FREQUENCIES_CMDLINE="${2-}"; shift;;
			-F) export FREQUENCY_LIMIT_CMDLINE="${2-}"; shift;;
			--frequencylimit) export FREQUENCY_LIMIT_CMDLINE="${2-}"; shift;;
			-p) export PHP_REPO_CMDLINE="${2-}"; shift;;
			--phprepo) export PHP_REPO_CMDLINE="${2-}"; shift;;
			-r) export RULES_CMDLINE="${2-}"; shift;;
			--rules) export RULES_CMDLINE="${2-}"; shift;;
			-s) export SPELL_PATH_CMDLINE="${2-}"; shift;;
			--spell) export SPELL_PATH_CMDLINE="${2-}"; shift;;
			-v) export VERBOSE=1;;
			--verbose) export VERBOSE=1;;
			*) echo "Unknown option $1. This is fatal. Aborting."; exit 1;;
			esac
			if [ -n "${1-}" ]; then
                        	shift
			fi
                else
                        break
                fi
        else
                break
        fi
done

if [ -n "$PHP_FUNCTIONS_FREQUENCIES_CMDLINE" ]; then
	if [ ! -f "$PHP_FUNCTIONS_FREQUENCIES_CMDLINE" ]; then
		echo "$PHP_FUNCTIONS_FREQUENCIES_CMDLINE is not existing. This is fatal. Aborting."
		exit 1
	else
		PHP_FUNCTIONS_FREQUENCIES=$PHP_FUNCTIONS_FREQUENCIES_CMDLINE
	fi
else
		PHP_FUNCTIONS_FREQUENCIES=$TMP_PHP_FUNCTIONS_FREQUENCIES
fi


if [ -n "$PHP_REPO_CMDLINE" ]; then
	if [ -d "$PHP_REPO_CMDLINE" ]; then
		PHP_REPO="$PHP_REPO_CMDLINE"
	else
		echo "Path to PHP repository passed on command line is not existing. This is fatal. Aborting."
		exit 1
	fi
fi

if [ -n "$AGE_LIMIT_CMDLINE" ]; then
	AGE_LIMIT="$AGE_LIMIT_CMDLINE"
fi

if [ -n "$FREQUENCY_LIMIT_CMDLINE" ]; then
	FREQUENCY_LIMIT="$FREQUENCY_LIMIT_CMDLINE"
fi


if [ -n "$RULES_CMDLINE" ]; then
	# Making sure the rules given on the cmd line can be accomodated for.
	echo "$RULES_CMDLINE" | tr " " "\n" | while read -r RULE; do
		echo "$RULE" | grep -E -q "^(933150|933151|933161)$"
		if [ $? -ne 0 ]; then
			echo "Rule $RULE is not available. This is fatal. Aborting."
			exit
		fi
	done
fi

if [ -n "$SPELL_PATH_CMDLINE" ]; then
	if [ ! -x "$SPELL_PATH_CMDLINE" ]; then
		echo "$SPELL_PATH_CMDLINE is not existing or is not executable. This is fatal. Aborting."
		exit 1
	else
		SPELL_PATH=$SPELL_PATH_CMDLINE
	fi
fi

# check if WordNet (wn) is installed
# We could also defer this test to spell.sh. But if done ourselves, we can
# control the error message and behavior.
if [ "$(command -v wn > /dev/null 2>&1 )" ]; then
	cat <<EOF
WordNet binary not found. This is fatal. Aborting.

This program depends on a script (spell.sh) that requires WordNet
to be installed.  The WordNet shell binary 'wn' can be obtained
via the package manager of your choice.

The package is usually called 'wordnet'.

EOF
	exit 1
fi


# check if GITHUB_TOKEN exists in env
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Env variable GITHUB_TOKEN to access GitHub is not set. This is fatal. Aborting."
    exit 1
fi




# --------------------------------------------------
# Main program
# --------------------------------------------------


# Step 0 - Init
echo "$RULES" | grep -q 933150
if [ $? -eq 0 ]; then
	DO_RULE_933150=1
fi
echo "$RULES" | grep -q 933151
if [ $? -eq 0 ]; then
	DO_RULE_933151=1
fi
echo "$RULES" | grep -q 933161
if [ $? -eq 0 ]; then
	DO_RULE_933161=1
fi


# Step 1 - Clone PHP repo
if [ -z "$PHP_REPO" ]; then
	echo -n "Cloning PHP repo ... "
	git clone --depth 1 $PHP_REPO_GITHUB "$TMPDIR" >/dev/null 2>&1
	ERROR=$(($ERROR|$?))    # logical OR
	break_on_error $ERROR
	echo "done"
	PHP_REPO="$TMPDIR"
else
	echo -n "Updating PHP repo ... "
	PWD_SAVE=$(pwd)
	cd $PHP_REPO || break_on_error 1 "Cannot cd to $PHP_REPO"
	git checkout master >/dev/null 2>&1
	git pull --depth 1 >/dev/null 2>&1
	ERROR=$(($ERROR|$?))    # logical OR
	break_on_error $ERROR
	echo "done"
	cd "$PWD_SAVE" || break_on_error 1 "Cannot cd back to $PWD_SAVE"
fi

# Step 2 - Extract Function Names
echo -n "Extracting PHP function names ... "
# Strings containing "$" are excluded (E.g. "{$this->getDeclarationName")
grep -o --no-file -R 'ZEND_FUNCTION(.*)' "$PHP_REPO" | grep -v '\$' | cut -f2 -d\( | cut -f1 -d\) | sort | uniq > $TMP_PHP_FUNCTIONS
ERROR=$(($ERROR|$?))    # logical OR
break_on_error $ERROR
echo "done ($(wc -l "$TMP_PHP_FUNCTIONS" | xargs echo | cut -d\  -f1 ) function names found)"

# Step 3 - Filter 1: Is it an English word
echo -n "Extracting English words out of list of PHP function names ... "
$SPELL_PATH --machine "$TMP_PHP_FUNCTIONS" > "$TMP_ENGLISH_WORDS"
ERROR=$(($ERROR|$?))    # logical OR
break_on_error $ERROR "$(cat "$TMP_ENGLISH_WORDS")"
echo "done ($(wc -l "$TMP_ENGLISH_WORDS" | xargs echo | cut -d\  -f1 ) english words found)"
# Step 4 - Output 933161
if [ "$DO_RULE_933161" == "1" ]; then
	# Being 933161 a stricter sibling of 933160, 933160 entries are also added to 933161.
	# We read the 933160 file skpping comments and empty lines. Entries are added to 933161 (if not already present).
	grep -v '^#' "$RA_FILE_PATH$R933160_FILENAME" | awk NF | while read -r R933160_ENTRY; do
		
		if [ $(grep -c -E "^$R933160_ENTRY$" "$TMP_ENGLISH_WORDS") -eq 0 ]; then
			# we have to add this function to 933161
			echo "Function \"$R933160_ENTRY\" from $R933160_FILENAME added to the stricter sibling $R933161_FILENAME"
			echo "$R933160_ENTRY" >> "$TMP_ENGLISH_WORDS"
		else
			echo "Function \"$R933160_ENTRY\" from $R933160_FILENAME already present in the stricter sibling $R933161_FILENAME"
		fi
	
	done

	sort -o "$TMP_ENGLISH_WORDS" "$TMP_ENGLISH_WORDS"
	echo -n "Writing output for rule 933161 to $R933161_FILENAME ... "
	echo -e "$R933161_PREFIX\n\n" > $RA_FILE_PATH$R933161_FILENAME
	cat "$TMP_ENGLISH_WORDS" >> $RA_FILE_PATH$R933161_FILENAME
	echo "done"
fi

# Step 5 - Create or update frequency list
echo "Creating / updating frequency list for functions (namely creating may take a while) ..."
sed -i -e "s/^/^/" -e "s/$/$/" "$TMP_ENGLISH_WORDS"
cat "$TMP_PHP_FUNCTIONS" | grep -v -E -f "$TMP_ENGLISH_WORDS" | while read -r FUNCTION; do

	grep -q -E "^$FUNCTION " "$PHP_FUNCTIONS_FREQUENCIES"
	if [ $? -ne 0 ]; then
		# function name not found in frequency list
		echo "Function $FUNCTION not found in frequency file. Attempting to add."
		NUM=$(get_frequency "$FUNCTION")
		if [ -z "$NUM" ]; then
			echo "  Retrieving frequency failed. Cannot add item."
		else
			echo "  Adding entry for function $FUNCTION with frequency $NUM"
			echo "$FUNCTION $NUM $MYDATE" >> "$PHP_FUNCTIONS_FREQUENCIES"
			sort -o "$PHP_FUNCTIONS_FREQUENCIES" "$PHP_FUNCTIONS_FREQUENCIES"
		fi
	else
		# function name found in frequency list
		TIMESTAMP=$(grep -E "^$FUNCTION " "$PHP_FUNCTIONS_FREQUENCIES" | cut -d\  -f3)
		TIMESTAMP_SECONDS=$(gdate -d "$TIMESTAMP" +%s 2>&1) # FIXME revert to date
		ERROR=$(($ERROR|$?))    # logical OR
		break_on_error $ERROR "$TIMESTAMP_SECONDS\nError. Check that date is the GNU date binary from coreutils."
		DIFF_SECONDS=$((MYDATE_SECONDS - TIMESTAMP_SECONDS))
		DIFF_DAYS=$(($DIFF_SECONDS / 86400))
		NUM=$(grep -E "^$FUNCTION " "$PHP_FUNCTIONS_FREQUENCIES" | cut -d\  -f2)
		vprint "Function $FUNCTION exists (timestamp: $TIMESTAMP, age: $DIFF_DAYS, frequency: $NUM)"
		if [ $DIFF_DAYS -gt "$AGE_LIMIT" ]; then
			NUM=$(get_frequency "$FUNCTION")
			if [ -z "$NUM" ]; then
				echo "Entry for function $FUNCTION is too old. Updating failed. Removing record."
				sed -i -e "/^$FUNCTION /d" "$PHP_FUNCTIONS_FREQUENCIES"
			else
				echo "Entry for function $FUNCTION is too old. Updating with new data (new frequency: $NUM)."
				sed -i -e "s/^$FUNCTION .*/$FUNCTION $NUM $MYDATE/" "$PHP_FUNCTIONS_FREQUENCIES"
			fi

		fi
	fi

done
echo "Done creating / updating frequency list."

# Step 6 - Filter 2: Output depending on frequency
echo "Starting filtering PHP functions names with frequency limit: $FREQUENCY_LIMIT..."
cat "$PHP_FUNCTIONS_FREQUENCIES" | cut -d\  -f1 | while read -r FUNCTION; do
	NUM=$(grep -E "^$FUNCTION " "$PHP_FUNCTIONS_FREQUENCIES" | cut -d\  -f2)
	if [ -n "$NUM" ] && [ "$NUM" -gt "$FREQUENCY_LIMIT" ]; then
		if [ "$DO_RULE_933150" == "1" ]; then
				echo "Function \"$FUNCTION\" (frequency $NUM) added to $R933150_FILENAME"
				echo "$FUNCTION" >> "$TMP_PHP_FUNCTIONS_FREQUENT"
		fi
	else
		if [ "$DO_RULE_933151" == "1" ]; then
				echo "Function \"$FUNCTION\" (frequency $NUM) added to $R933151_FILENAME"
				echo "$FUNCTION" >> "$TMP_PHP_FUNCTIONS_RARE"
		fi
	fi
done

echo "Done filtering PHP functions names."
if [ -s "$TMP_PHP_FUNCTIONS_FREQUENCIES_ERRORS" ]; then
	FAILED_COUNTER=$(echo "$PHP_FUNCTIONS_FREQUENCIES_ERRORS" | wc -l | xargs echo)
	echo -n "Failed to retrieve frequency for $FAILED_COUNTER function(s)"
	if [ $VERBOSE -eq 1 ]; then
		echo ":"
		cat "$TMP_PHP_FUNCTIONS_FREQUENCIES_ERRORS"
		else
		echo "."
	fi
fi

if [ "$DO_RULE_933150" == "1" ]; then
	# 933150 comes with a second source of non english words high-risk php functions.
	# Any occurrence that is part of that list and not already in 933150 is now added.
	cat "$HIGH_RISK_FUNCTIONS_FILENAME" | while read -r HIGH_RISK_FUNC; do
		if [ $(grep -c -E "^$HIGH_RISK_FUNC$" "$TMP_PHP_FUNCTIONS_FREQUENT") -eq 0 ]; then
			# we have to add this function to 933150
			echo "High-risk function \"$HIGH_RISK_FUNC\" added to $R933150_FILENAME"
			echo "$HIGH_RISK_FUNC" >> "$TMP_PHP_FUNCTIONS_FREQUENT"
		else
			echo "High-risk function \"$HIGH_RISK_FUNC\" already present in $R933150_FILENAME"
		fi
	
	done
	sort -o "$TMP_PHP_FUNCTIONS_FREQUENT" "$TMP_PHP_FUNCTIONS_FREQUENT"
	echo "File $R933150_FILENAME updated."
	cat "$TMP_PHP_FUNCTIONS_FREQUENT" > $DATA_FILE_PATH$R933150_FILENAME
fi
if [ "$DO_RULE_933151" == "1" ]; then
	echo "File $R933151_FILENAME updated."
	cat "$TMP_PHP_FUNCTIONS_RARE" > $DATA_FILE_PATH$R933151_FILENAME
fi

if [ "$DO_RULE_933161" == "1" ]; then
	echo "933161.ra file updated, mind to call the crs-toolchain regex update before committing changes"
fi

TIME_END=$(date +"%s")
echo "The script took $((TIME_END-MYDATE_SECONDS)) seconds to complete."


# --------------------------------------------------
# Cleanup
# --------------------------------------------------

# Temp files are cleaned via trap set above.
