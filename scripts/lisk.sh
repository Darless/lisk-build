#!/bin/bash

cd "$(cd -P -- "$(dirname -- "$0")" && pwd -P)" || exit 2

if [ "$USER" == "root" ]; then
	echo "Error: Lisk should not be run be as root. Exiting."
	exit 1
fi

# shellcheck disable=SC1090
. "$(pwd)/shared.sh"
# shellcheck disable=SC1090
. "$(pwd)/env.sh"

# Declare static config for redis
REDIS_CONFIG="$(pwd)/etc/redis.conf"
REDIS_BIN="$(pwd)/bin/redis-server"
REDIS_CLI="$(pwd)/bin/redis-cli"
REDIS_PID="$(pwd)/redis/redis_6380.pid"

# Declare static config for postgresql
DB_DATA="$(pwd)/blockchain.db"
DB_LOG_FILE="$(pwd)/pgsql.log"
DB_SNAPSHOT="blockchain.db.gz"
DB_DOWNLOAD=Y

PM2_MAIN_CONFIG="$(pwd)/etc/pm2-lisk-main.json"
PM2_TEST_CONFIG="$(pwd)/etc/pm2-lisk-test.json"
PM2_DEV_CONFIG="$(pwd)/etc/pm2-lisk-dev.json"

LOGS_DIR="$(pwd)/logs"

config() {
	# Initalize application specific Postgresql variables
	DB_NAME="$(jq .db.database -r "$LISK_CONFIG")"
	DB_PORT="$(jq .db.port -r "$LISK_CONFIG")"
	DB_USER="$USER"
	DB_PASS="$(jq .db.password -r "$LISK_CONFIG")"

	# Initialize application specific Redis variables
	REDIS_ENABLED="$(jq .cacheEnabled -r "$LISK_CONFIG")"
	REDIS_PORT="$(jq .redis.port -r "$LISK_CONFIG")"
	REDIS_PASSWORD="$(jq .redis.password -r "$LISK_CONFIG")"

	# Initialize Lisk specific variables.
	PM2_APP="$(jq .apps[].name -r "$PM2_CONFIG")"
	LISK_LOGS="./$NETWORK/$(jq .logFileName -r "$LISK_CONFIG")"
}

# Declares shell script log file
SH_LOG_FILE="$LOGS_DIR/lisk.out"

# Setup logging
exec > >(tee -ia "$SH_LOG_FILE")
exec 2>&1

################################################################################

blockheight() {
	DB_HEIGHT="$(psql -d "$DB_NAME" -t -p "$DB_PORT" -c 'select height from blocks order by height desc limit 1;')"
	HEIGHT="${DB_HEIGHT:- Unavailable}"
	echo -e "Current Block Height:" "$HEIGHT"
}

create_user() {
	dropuser --if-exists "$DB_USER" >> "$SH_LOG_FILE" 2>&1
	createuser --createdb "$DB_USER" >> "$SH_LOG_FILE" 2>&1
	if ! psql -qd postgres -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';" >> "$SH_LOG_FILE" 2>&1; then
		echo "X Failed to create Postgresql user."
		exit 1
	else
		echo "√ Postgresql user created successfully."
	fi
}

create_database() {
	dropdb --if-exists "$DB_NAME" >> "$SH_LOG_FILE" 2>&1

	if ! createdb "$DB_NAME" >> "$SH_LOG_FILE" 2>&1; then
		echo "X Failed to create Postgresql database."
		exit 1
	else
		echo "√ Postgresql database created successfully."
	fi
}

populate_database() {
	if psql -ltAq | grep -q "^$DB_NAME|" >> "$SH_LOG_FILE" 2>&1; then
		download_blockchain
		restore_blockchain
	fi
}

download_blockchain() {
	if [ "$DB_DOWNLOAD" = "Y" ]; then
		rm -f "$DB_SNAPSHOT"
		if [ "$BLOCKCHAIN_URL" = "" ]; then
			BLOCKCHAIN_URL="https://downloads.lisk.io/lisk/$NETWORK"
		fi
		echo '√ Downloading '"$DB_SNAPSHOT"' from '"$BLOCKCHAIN_URL"

		if ! curl --progress-bar -o "$DB_SNAPSHOT" "$BLOCKCHAIN_URL/$DB_SNAPSHOT"; then
			rm -f "$DB_SNAPSHOT"
			echo "X Failed to download blockchain snapshot."
			exit 1
		else
			# Required to clean up ugly curl output in the logs
			sed -i -e '/[#]/d' "$SH_LOG_FILE"
			echo "√ Blockchain snapshot downloaded successfully."
		fi
	else
		echo -e "√ Using Local Snapshot."
	fi
}

restore_blockchain() {
	echo 'Restoring blockchain with '"$DB_SNAPSHOT"

	if ! gunzip -fcq "$DB_SNAPSHOT" | psql -q -U "$DB_USER" -d "$DB_NAME" >> "$SH_LOG_FILE" 2>&1; then
		echo "X Failed to restore blockchain."
		exit 1
	else
		echo "√ Blockchain restored successfully."
	fi
}

autostart_cron() {
	local cmd="crontab"

	if ! command -v "$cmd" > /dev/null 2>&1; then
		echo "X Failed to execute crontab."
		return 1
	fi

	crontab=$($cmd -l 2> /dev/null | sed '/lisk\.sh start/d' 2> /dev/null)

	crontab=$(cat <<-EOF
		$crontab
		@reboot $(command -v "bash") $(pwd)/lisk.sh start > $(pwd)/cron.log 2>&1
EOF
	)

	if ! printf "%s\n" "$crontab" | $cmd - >> "$SH_LOG_FILE" 2>&1; then
		echo "X Failed to update crontab."
		return 1
	else
		echo "√ Crontab updated successfully."
		return 0
	fi
}

coldstart_lisk() {
	stop_lisk >> "$SH_LOG_FILE" 2>&1
	stop_postgresql >> "$SH_LOG_FILE" 2>&1
	rm -rf "$DB_DATA"
	pg_ctl initdb -D "$DB_DATA" >> "$SH_LOG_FILE" 2>&1
	sleep 2
	start_postgresql
	sleep 1
	create_user
	create_database
	populate_database
	autostart_cron
	start_lisk
}

start_postgresql() {
	if pgrep -x "postgres" > /dev/null 2>&1; then
		echo "√ Postgresql is running."
	else
		if ! pg_ctl -D "$DB_DATA" -l "$DB_LOG_FILE" start >> "$SH_LOG_FILE" 2>&1; then
			echo "X Failed to start Postgresql."
			exit 1
		else
			echo "√ Postgresql started successfully."
		fi
	fi
}

stop_postgresql() {
	if ! pgrep -x "postgres" > /dev/null 2>&1; then
		echo "√ Postgresql is not running."
	else
		if pg_ctl -D "$DB_DATA" -l "$DB_LOG_FILE" stop >> "$SH_LOG_FILE" 2>&1; then
			echo "√ Postgresql stopped successfully."
			else
			echo "X Postgresql failed to stop."
		fi
		if pgrep -x "postgres" >> "$SH_LOG_FILE" 2>&1; then
			pkill -x postgres -9 >> "$SH_LOG_FILE" 2>&1;
			echo "√ Postgresql Killed."
		fi
	fi
}

start_redis() {
	if [[ "$REDIS_ENABLED" == 'true' ]]; then
		if [[ "$REDIS_PORT" == '6379' ]]; then
			echo "√ Using OS Redis-Server, skipping startup"
		elif [[ ! -f "$REDIS_PID" ]]; then

			if "$REDIS_BIN" "$REDIS_CONFIG"; then
				echo "√ Redis-Server started successfully."
			else
				echo "X Failed to start Redis-Server."
				exit 1
			fi
		else
			echo "√ Redis-Server is already running"
		fi
	fi
}

stop_redis() {
	if [[ "$REDIS_ENABLED" == 'true' ]]; then
		if [[ "$REDIS_PORT" == '6379' ]]; then
			echo "√ OS Redis-Server detected, skipping shutdown"
		elif [[ -f "$REDIS_PID" ]]; then

			if stop_redis_cmd; then
				echo "√ Redis-Server stopped successfully."
			else
				echo "X Failed to stop Redis-Server."
				REDIS_PID="$(tail -n1 "$REDIS_PID")"
				pkill -9 "$REDIS_PID"
				echo "√ Redis-Server killed"
			fi
		else
			echo "√ Redis-Server already stopped"
		fi
	fi
}

stop_redis_cmd(){
	# Necessary to pass the right password string to redis
	if [[ "$REDIS_PASSWORD" != null ]]; then
		"$REDIS_CLI" -p "$REDIS_PORT" "-a $REDIS_PASSWORD" shutdown
	else
		"$REDIS_CLI" -p "$REDIS_PORT" shutdown
	fi
}

start_lisk() {
	start_redis
	if pm2 start "$PM2_CONFIG"  >> "$SH_LOG_FILE"; then
		echo "√ Lisk started successfully."
		sleep 3
		check_status
	else
		echo "X Failed to start Lisk."
	fi
}

stop_lisk() {
	pm2 delete "$PM2_CONFIG" >> "$SH_LOG_FILE"
	echo "√ Lisk stopped successfully."
	stop_redis
}

reload_lisk() {
	echo "Stopping Lisk to reload PM2 config"
	stop_lisk
	start_lisk
}

rebuild_lisk() {
	create_database
	download_blockchain
	restore_blockchain
}

pm2_cleanup() {
	pm2 delete all
	pm2 kill
}

check_status() {
	PM2_PID="$( pm2 jlist |jq ".[] | select(.name == \"$PM2_APP\").pm2_env.pm_pid_path" )"

	pm2 describe "$PM2_APP" >> "$SH_LOG_FILE"

	check_pid
	if [ "$STATUS" -eq 0  ]; then
		echo "√ Lisk is running as PID: $PID"
		blockheight
	else
		echo "X Lisk is not running"
		exit 1
	fi
}

check_pid() {
	if [ -f "$PM2_PID" ]; then
	read -r PID < "$PM2_PID" 2>&1 > /dev/null
	fi
	if [ ! -z "$PID" ]; then
		ps -p "$PID" > /dev/null 2>&1
		STATUS=$?
	else
		STATUS=1
	fi
}

lisky() {
	node "$(pwd)/bin/lisky"
}

tail_logs() {
	tail -f "$LISK_LOGS"
}

help() {
	echo -e "\nCommand Options for Lisk.sh"
	echo -e "\nAll options may be passed [-p <PM2-config.json>]"
	echo -e "\nstart_node                            Starts a Nodejs process for Lisk"
	echo -e "start                                 Starts the Nodejs process and PostgreSQL Database for Lisk"
	echo -e "stop_node                             Stops a Nodejs process for Lisk"
	echo -e "stop                                  Stop the Nodejs process and PostgreSQL Database for Lisk"
	echo -e "reload                                Restarts the Nodejs process for Lisk"
	echo -e "rebuild [-u URL] [-f file.db.gz] [-0] Rebuilds the PostgreSQL database"
	echo -e "start_db                              Starts the PostgreSQL database"
	echo -e "stop_db                               Stops the PostgreSQL database"
	echo -e "coldstart                             Creates the PostgreSQL database and configures config.json for Lisk"
	echo -e "lisky                                 Launches Lisky"
	echo -e "logs                                  Displays and tails logs for Lisk"
	echo -e "status                                Displays the status of the PID associated with Lisk"
	echo -e "help                                  Displays this message"
}

# Parses flags for instance
parse_flag() {
	OPTIND=2
	while getopts ":p:f:u:l:0" OPT; do
		case "$OPT" in
			p)
				if [ -f "$OPTARG" ]; then
					PM2_CONFIG="$OPTARG"
					PM2_APP="$( jq .apps[0].name -r "$PM2_CONFIG" )"
					LISK_CONFIG="$( jq .apps[0].args -r "$PM2_CONFIG" |cut -d' ' -f2 )"
					# Resets all of the variables
					config
				else
					echo "PM2-config.json not found. Please verify the file exists and try again."
					exit 1
				fi ;;

			u)
				BLOCKCHAIN_URL="$OPTARG"
				;;

			f)
				DB_SNAPSHOT="$OPTARG"
				if [ -f "$OPTARG" ]; then
					DB_DOWNLOAD=N
				fi ;;

			0)
				DB_SNAPSHOT="$(pwd)/etc/blockchain.db.gz"
				DB_DOWNLOAD=N
				;;

			 :) echo 'Missing option argument for -'"$OPTARG" >&2; exit 1;;

			 *) echo 'Unimplemented option: -'"$OPTARG" >&2; exit 1;;
		esac
	done
}

# Parses network
case $2 in
	"mainnet")
		NETWORK="mainnet"
		PM2_CONFIG="$PM2_MAIN_CONFIG"
		LISK_CONFIG="./mainnet/config.json"
		;;
	"testnet")
		NETWORK="testnet"
		PM2_CONFIG="$PM2_TEST_CONFIG"
		LISK_CONFIG="./testnet/config.json"
		;;
	"devnet")
		NETWORK="devnet"
		PM2_CONFIG="$PM2_DEV_CONFIG"
		LISK_CONFIG="./devnet/config.json"
		;;
	*)
		echo "No network specified. Please specify a network: mainnet, testnet, devnet"
		echo "Exiting..."
		exit 0
		;;
esac

echo -e 'Lisk configured for '"$NETWORK"' network\n' >> "$SH_LOG_FILE"

# Calls config function declare mutable variables
config

# Parsing flags after setting network
parse_flag "$@"

# Parses command to run with above
case $1 in
	"coldstart")
		coldstart_lisk
		;;
	"start_node")
		start_lisk
		;;
	"start")
		start_postgresql
		sleep 2
		start_lisk
		;;
	"stop_node")
		stop_lisk
		;;
	"stop")
		stop_lisk
		stop_postgresql
		;;
	"reload")
		reload_lisk
		;;
	"rebuild")
		stop_lisk
		sleep 1
		start_postgresql
		sleep 1
		rebuild_lisk
		start_lisk
		;;
	"start_db")
		start_postgresql
		;;
	"stop_db")
		stop_postgresql
		;;
	"cleanup")
		pm2_cleanup
		;;
	"status")
		check_status
		;;
	"logs")
		tail_logs
		;;
	"lisky")
		lisky
		;;
	"help")
		help
		;;
	*)
		echo "Error: Unrecognized command."
		echo ""
		echo "Available commands are: start stop start_node stop_node start_db stop_db reload rebuild coldstart logs lisky status help"
		help
		;;
esac

# Required to clean up colour characters that don't translate well from tee
sed -i -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g" "$SH_LOG_FILE"
