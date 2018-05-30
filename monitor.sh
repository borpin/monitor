
#!/bin/bash

# ----------------------------------------------------------------------------------------
# GENERAL INFORMATION
# ----------------------------------------------------------------------------------------
#
# Written by Andrew J Freyer
# GNU General Public License
# http://github.com/andrewjfreyer/presence
#
# Credits to:
#		Radius Networks iBeacon Script
#			• http://developer.radiusnetworks.com/ibeacon/idk/ibeacon_scan
#
#		Reely Active advlib
#			• https://github.com/reelyactive/advlib
#
#                        _ _             
#                       (_) |            
#  _ __ ___   ___  _ __  _| |_ ___  _ __ 
# | '_ ` _ \ / _ \| '_ \| | __/ _ \| '__|
# | | | | | | (_) | | | | | || (_) | |   
# |_| |_| |_|\___/|_| |_|_|\__\___/|_|
#
# ----------------------------------------------------------------------------------------

#VERSION NUMBER
version=0.1.81

#COLOR OUTPUT FOR RICH OUTPUT 
ORANGE='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
BLUE='\033[0;34m'

#FIND DEPENDENCY PATHS, ELSE MANUALLY SET
mosquitto_pub_path=$(which mosquitto_pub)
mosquitto_sub_path=$(which mosquitto_sub)
hcidump_path=$(which hcidump)
bc_path=$(which bc)
git_path=$(which git)

#ERROR CHECKING FOR MOSQUITTO PUBLICATION 
should_exit=false
[ -z "$mosquitto_pub_path" ] && echo -e "${RED}Error: ${NC}Required package 'mosquitto_pub' not found. Please install." && should_exit=true
[ -z "$mosquitto_sub_path" ] && echo -e "${RED}Error: ${NC}Required package 'mosquitto_sub' not found. Please install." && should_exit=true
[ -z "$hcidump_path" ] && echo -e "${RED}Error: ${NC}Required package 'hcidump' not found. Please install." && should_exit=true
[ -z "$bc_path" ] && echo -e "${RED}Error: ${NC}Required package 'bc' not found. Please install." && should_exit=true
[ -z "$git_path" ] && echo -e "${ORANGE}Warning: ${NC}Recommended package 'git' not found. Please consider installing."

#BASE DIRECTORY REGARDLESS OF INSTALLATION; ELSE MANUALLY SET HERE
base_directory=$(dirname "$(readlink -f "$0")")

#MQTT PREFERENCES
MQTT_CONFIG="$base_directory/mqtt_preferences"
if [ -f $MQTT_CONFIG ]; then 
	source $MQTT_CONFIG

	#DOUBLECHECKS 
	[ "$mqtt_address" == "0.0.0.0" ] && echo -e "${RED}Error: ${NC}Please customize mqtt broker address in: ${BLUE}mqtt_preferences${NC}" && should_exit=true
	[ "$mqtt_user" == "username" ] && echo -e "${RED}Error: ${NC}Please customize mqtt username in: ${BLUE}mqtt_preferences${NC}" && should_exit=true
	[ "$mqtt_password" == "password" ] && echo -e "${RED}Error: ${NC}Please customize mqtt password in: ${BLUE}mqtt_preferences${NC}" && should_exit=true
else
	echo "Mosquitto preferences file created. Please customize." 

	#LOAD A DEFULT PREFERENCES FILE
	echo "# ---------------------------" >> $MQTT_CONFIG
	echo "#								" >> $MQTT_CONFIG
	echo "# MOSQUITTO PREFERENCES" >> $MQTT_CONFIG
	echo "#								" >> $MQTT_CONFIG
	echo "# ---------------------------" >> $MQTT_CONFIG
	echo "" >> $MQTT_CONFIG

	echo "# IP ADDRESS OF MQTT BROKER" >> $MQTT_CONFIG
	echo "mqtt_address=0.0.0.0" >> $MQTT_CONFIG

	echo "" >> $MQTT_CONFIG
	echo "# MQTT BROKER USERNAME (OR BLANK FOR NONE)" >> $MQTT_CONFIG
	echo "mqtt_user=username" >> $MQTT_CONFIG

	echo "" >> $MQTT_CONFIG
	echo "# MQTT BROKER PASSWORD (OR BLANK FOR NONE)" >> $MQTT_CONFIG
	echo "mqtt_password=password" >> $MQTT_CONFIG

	echo "" >> $MQTT_CONFIG
	echo "# MQTT PUBLISH TOPIC ROOT " >> $MQTT_CONFIG
	echo "mqtt_topicpath=location" >> $MQTT_CONFIG

	echo "" >> $MQTT_CONFIG
	echo "# PUBLISHER IDENTITY " >> $MQTT_CONFIG
	echo "mqtt_publisher_identity=''" >> $MQTT_CONFIG

	#SET SHOULD EXIT
	should_exit=true
fi 

#MQTT PREFERENCES
PUB_CONFIG="$base_directory/public_addresses"
if [ -f "$PUB_CONFIG" ]; then 
	#DOUBLECHECKS 
	[ ! -z "$(cat "$PUB_CONFIG" | grep "^00:00:00:00:00:00")" ] && echo -e "${RED}Error: ${NC}Please customize public mac addresses in: ${BLUE}public_addresses${NC}" && should_exit=true
else
	echo "Public MAC address list file created. Please customize."
	#IF NO PUBLIC ADDRESS FILE; LOAD 
	echo "# ---------------------------" >> $PUB_CONFIG
	echo "#" >> $PUB_CONFIG
	echo "# PUBLIC MAC ADDRESS LIST" >> $PUB_CONFIG
	echo "#" >> $PUB_CONFIG
	echo "# ---------------------------" >> $PUB_CONFIG
	echo "" >> $PUB_CONFIG
	echo "00:00:00:00:00:00 Nickname #comment" >> $PUB_CONFIG

	#SET SHOULD EXIT
	should_exit=true
fi 

#ARE REQUIREMENTS MET? 
[ "$should_exit" == true ] && exit 1

# ----------------------------------------------------------------------------------------
# DEFINE VALUES AND VARIABLES
# ----------------------------------------------------------------------------------------

#CYCLE BLUETOOTH INTERFACE 
sudo hciconfig hci0 down && sudo hciconfig hci0 up

#SETUP MAIN PIPE
sudo rm main_pipe &>/dev/null
mkfifo main_pipe

#SETUP SCAN PIPE
sudo rm scan_pipe &>/dev/null
mkfifo scan_pipe

#DEFINE VARIABLES FOR EVENT PROCESSING
declare -A device_log

#LOAD PUBLIC ADDRESSES TO SCAN INTO ARRAY
public_addresses=($(cat "$base_directory/public_addresses" | grep -ioE "^.*?#" | awk '{print $1}' | grep -oiE "([0-9a-f]{2}:){5}[0-9a-f]{2}" ))

#LOOP SCAN VARIABLES
device_count=${#public_addresses[@]}
device_index=0
last_random=""

# ----------------------------------------------------------------------------------------
# BLUETOOTH LE BACKGROUND SCANNING
# ----------------------------------------------------------------------------------------
bluetooth_scanner () {
	echo "BTLE scanner started" >&2 
	while true; do 
		#TIMEOUT THE HCITOOL SCAN TO RESHOW THE DUPLICATES WITHOUT SPAMMING THE MAIN LOOP BY USING THE --DUPLICATES TAG
		local error=$(sudo timeout --signal SIGINT 120 hcitool lescan 2>&1 | grep -iE 'input/output error|invalid device|invalid|error')
		[ ! -z "$error" ] && echo "ERRO$error" > main_pipe
		sleep 1
	done
}

# ----------------------------------------------------------------------------------------
# BLUETOOTH LE RAW PACKET ANALYSIS
# ----------------------------------------------------------------------------------------
btle_listener () {
	echo "BTLE trigger started" >&2 
	
	#DEFINE VARAIBLES
	local capturing=""
	local next_packet=""
	local packet=""

	while read segment; do

		#MATCH A SECOND OR LATER SEGMENT OF A PACKET
		if [[ $segment =~ ^[0-9a-fA-F]{2}\ [0-9a-fA-F] ]]; then
			#KEEP ADDING TO NEXT PACKET
			next_packet="$next_packet $segment"
			continue

		elif [[ $segment =~ ^\> ]]; then
			#NEW PACKET STARTS
			packet=$next_packet
			next_packet=$(echo $segment | sed 's/^>.\(.*$\)/\1/')
		elif [[ $segment =~ ^\< ]]; then
			#INPUT COMMAND; SHOULD IGNORE LATER
			packet=$next_packet
			next_packet=$(echo $segment | sed 's/^>.\(.*$\)/\1/')
		fi

		#BEACON PACKET?
		if [[ $packet =~ ^04\ 3E\ 2A\ 02\ 01\ .{26}\ 02\ 01\ .{14}\ 02\ 15 ]] && [ ${#packet} -gt 132 ]; then

			#RAW VALUES
			local UUID=$(echo $packet | sed 's/^.\{69\}\(.\{47\}\).*$/\1/')
			local MAJOR=$(echo $packet | sed 's/^.\{117\}\(.\{5\}\).*$/\1/')
			local MINOR=$(echo $packet | sed 's/^.\{123\}\(.\{5\}\).*$/\1/')
			local POWER=$(echo $packet | sed 's/^.\{129\}\(.\{2\}\).*$/\1/')
			local UUID=$(echo $UUID | sed -e 's/\ //g' -e 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')

			#MAJOR CALCULATION
			MAJOR=$(echo $MAJOR | sed 's/\ //g')
			MAJOR=$(echo "ibase=16; $MAJOR" | bc)

			#MINOR CALCULATION
			MINOR=$(echo $MINOR | sed 's/\ //g')
			MINOR=$(echo "ibase=16; $MINOR" | bc)

			#POWER CALCULATION
			POWER=$(echo "ibase=16; $POWER" | bc)
			POWER=$[POWER - 256]

			#RSSI CALCULATION
			RSSI=$(echo $packet | sed 's/^.\{132\}\(.\{2\}\).*$/\1/')
			RSSI=$(echo "ibase=16; $RSSI" | bc)
			RSSI=$[RSSI - 256]

            #ADD BEACON 
            key_identifier="$UUID-$MAJOR-$MINOR"

            #CLEAR PACKET
            packet=""

			#SEND TO MAIN LOOP
			echo "BEAC$UUID|$MAJOR|$MINOR|$RSSI|$POWER" > main_pipe
		fi

		#FIND ADVERTISEMENT PACKET OF RANDOM ADDRESSES                                  __
		if [[ $packet =~ ^04\ 3E\ [0-9a-fA-F]{2}\ 02\ [0-9a-fA-F]{2}\ [0-9a-fA-F]{2}\ 01\ .*? ]]; then
			
			#GET RANDOM ADDRESS; REVERSE FROM BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $13":"$12":"$11":"$10":"$9":"$8}')


            #CLEAR PACKET
            packet=""

			#SEND TO MAIN LOOP
			echo "RAND$received_mac_address" > main_pipe

		fi

		#FIND ADVERTISEMENT PACKET OF PUBLIC ADDRESSES                                  __
		if [[ $packet =~ ^04\ 3E\ [0-9a-fA-F]{2}\ 02\ [0-9a-fA-F]{2}\ [0-9a-fA-F]{2}\ 00\ .*? ]]; then
			
			#GET RANDOM ADDRESS; REVERSE FROM BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $13":"$12":"$11":"$10":"$9":"$8}')

            #CLEAR PACKET
            packet=""

			#SEND TO MAIN LOOP
			echo "PUBL$received_mac_address" > main_pipe
		fi 

		#NAME RESPONSE 
		if [[ $packet =~ ^04\ 07\ FF\ .*? ]] && [ ${#packet} -gt 700 ]; then

			packet=$(echo "$packet" | tr -d '\0')

			#GET HARDWARE MAC ADDRESS FOR THIS REQUEST; REVERSE FOR BIG ENDIAN
			local received_mac_address=$(echo "$packet" | awk '{print $10":"$9":"$8":"$7":"$6":"$5}')

			#CONVERT RECEIVED HEX DATA INTO ASCII
			local name_as_string=$(echo -e "${packet:29}" | sed 's/ 00//g' | xxd -r -p )

            #CLEAR PACKET
            packet=""

			#SEND TO MAIN LOOP; FORK FOR FASTER RESPONSE
			echo "NAME$received_mac_address|$name_as_string" > main_pipe &
		fi
	done < <(sudo hcidump --raw)
}

# ----------------------------------------------------------------------------------------
# MQTT LISTENER
# ----------------------------------------------------------------------------------------
mqtt_listener (){
	echo "MQTT trigger started" >&2 
	#MQTT LOOP
	while read instruction; do 
		echo "MQTT$instruction" > main_pipe
	done < <($(which mosquitto_sub) -v -h "$mqtt_address" -u "$mqtt_user" -P "$mqtt_password" -t "$mqtt_topicpath/scan") 
}

# ----------------------------------------------------------------------------------------
# PERIODIC TRIGGER TO MAIN LOOP
# ----------------------------------------------------------------------------------------
periodic_trigger (){
	echo "TIME trigger started" >&2 
	#MQTT LOOP
	while : ; do 
		sleep 60
		echo "TIME" > main_pipe
	done
}

# ----------------------------------------------------------------------------------------
# OBTAIN MANUFACTURER INFORMATION FOR A PARTICULAR BLUETOOTH MAC ADDRESS
# ----------------------------------------------------------------------------------------
determine_manufacturer () {

	#IF NO ADDRESS, RETURN BLANK
	if [ ! -z "$1" ]; then  
		local address="$1"

		#SET THE FILE IF IT DOESN'T EXIST
		[ ! -f ".manufacturer_cache" ] && echo "" > ".manufacturer_cache"

		#CHECK CACHE
		local manufacturer=$(cat ".manufacturer_cache" | grep "${address:0:8}" | awk -F "\t" '{print $2}')

		#IF CACHE DOES NOT EXIST, USE MACVENDORS.COM
		if [ -z "$manufacturer" ]; then 
			local remote_result=$(curl -sL https://api.macvendors.com/${address:0:8} | grep -vi "error")
			[ ! -z "$remote_result" ] && echo -e "${address:0:8}	$remote_result" >> .manufacturer_cache
			manufacturer="$remote_result"
		fi

		#SET DEFAULT MANUFACTURER 
		[ -z "$manufacturer" ] && manufacturer="Unknown"
		echo "$manufacturer"
	fi 
}

# ----------------------------------------------------------------------------------------
# PUBLIC DEVICE ADDRESS SCAN LOOP
# ----------------------------------------------------------------------------------------
public_device_scanner () {
	echo "Public scanner started" >&2 
	local scan_event_received=false

	#PUBLIC DEVICE SCANNER LOOP
	while true; do 
		#SET SCAN EVENT
		scan_event_received=false

		#READ FROM THE MAIN PIPE
		while read scan_event; do 
			#SET SCAN EVENT RECEIVED
			scan_event_received=true

			#ONLY SCAN FOR PROPERLY-FORMATTED MAC ADDRESSES
			local mac=$(echo "$scan_event" | awk -F "|" '{print $1}' | grep -ioE "([0-9a-f]{2}:){5}[0-9a-f]{2}")
			local previous_status=$( echo "$scan_event" | awk -F "|" '{print $2}' | grep -ioE  "[0-9]{1,")

			#HAS THIS DEVICE BEEN SCANNED PREVIOUSLY? 
			[ -z "$previous_status" ] && previous_status=0

			echo -e "${GREEN}[CMD-SCAN]	${GREEN}Scanning:${NC} $mac${NC}"

			#HCISCAN
			name=$(hcitool name "$mac" | grep -iE 'input/output error|invalid device|invalid|error')

			#DELAY BETWEEN SCANS
			sleep 3

			#IF WE HAVE A BLANK NAME AND THE PREVIOUS STATE OF THIS PUBLIC MAC ADDRESS
			#WAS A NON-ZERO VALUE, THEN WE PROCEED INTO A VERIFICATION LOOP
			if [ -z "$name" ]; then 
				if [ "$previous_status" -gt "0" ]; then  
					#SHOULD VERIFY ABSENSE
					for repetition in $(seq 1 4); do 
						#DEBUGGING
						echo -e "${GREEN}[CMD-VERI]	${GREEN}Verify:${NC} $mac${NC}"

						#HCISCAN
						name=$(hcitool name "$mac" | grep -iE 'input/output error|invalid device|invalid|error')

						#BREAK IF NAME IS FOUND
						[ ! -z "$name" ] && break

						#DELAY BETWEEN SCANS
						sleep 3
					done
				fi  
			fi 

			#SCAN FORMATTING; REVERSE MAC ADDRESS FOR BIG ENDIAN
			#hcitool cmd 0x01 0x0019 $(echo "$mac" | awk -F ":" '{print "0x"$6" 0x"$5" 0x"$4" 0x"$3" 0x"$2" 0x"$1}') 0x02 0x00 0x00 0x00 &>/dev/null

			#TESTING
			echo -e "${GREEN}[CMD-SCAN]	${GREEN}Complete:${NC} $mac${NC}"

			#SLEEP AGAIN; DO NOT SCAN TOO FREQUENTLY
			sleep 2

		done < <(cat < scan_pipe)

		#PREVENT UNNECESSARILY FAST LOOPING
		[ "$scan_event_received" == false ] && sleep 3
	done 
}

# ----------------------------------------------------------------------------------------
# PUBLISH MESSAGE
# ----------------------------------------------------------------------------------------

publish_message () {
	if [ ! -z "$1" ]; then 

		#SET NAME FOR 'UNKONWN'
		local name="$3"
		local confidence="$3"
		[ -z "$confidence" ] && confidence=0

		#IF NO NAME, RETURN "UNKNOWN"
		if [ -z "$name" ]; then 
			name="Unknown"
		fi 

		#TIMESTAMP
		stamp=$(date "+%a %b %d %Y %H:%M:%S GMT%z (%Z)")

		#DEBUGGING 
		(>&2 echo -e "${PURPLE}$mqtt_topicpath/owner/$1 { confidence : $2, name : $name, timestamp : $stamp, manufacturer : $4} ${NC}")

		#POST TO MQTT
		$mosquitto_pub_path -h "$mqtt_address" -u "$mqtt_user" -P "$mqtt_password" -t "$mqtt_topicpath/owner/$mqtt_publisher_identity/$1" -m "{\"confidence\":\"$2\",\"name\":\"$name\",\"timestamp\":\"$stamp\",\"manufacturer\":\"$4\"}"
	fi
}

# ----------------------------------------------------------------------------------------
# CLEANUP ROUTINE 
# ----------------------------------------------------------------------------------------
clean() {
	#CLEANUP FOR TRAP
	while read line; do 
		`sudo kill $line` &>/dev/null
	done < <(ps ax | grep monitor.sh | awk '{print $1}')

	#REMOVE PIPES
	sudo rm main_pipe &>/dev/null
	sudo rm scan_pipe &>/dev/null

	#MESSAGE
	echo 'Exited.'
}

trap "clean" EXIT


# ----------------------------------------------------------------------------------------
# OBTAIN PIDS OF BACKGROUND PROCESSES FOR TRAP
# ----------------------------------------------------------------------------------------
bluetooth_scanner & 
mqtt_listener &
btle_listener &
periodic_trigger & 
public_device_scanner & 

# ----------------------------------------------------------------------------------------
# MAIN LOOPS. INFINITE LOOP CONTINUES, NAMED PIPE IS READ INTO SECONDARY LOOP
# ----------------------------------------------------------------------------------------

#MAIN LOOP
while true; do 
	event_received=false

	#READ FROM THE MAIN PIPE
	while read event; do 
		#EVENT RECEIVED
		event_received=true

		#DIVIDE EVENT MESSAGE INTO TYPE AND DATA
		cmd="${event:0:4}"
		data="${event:4}"
		timestamp=$(date +%s)

		#FLAGS TO DETERMINE FRESHNESS OF DATA
		is_new=false
		did_change=false

		#DATA FOR PUBLICATION
		manufacturer=""
		name=""

		#PROCEED BASED ON COMMAND TYPE
		if [ "$cmd" == "RAND" ]; then 
			#DATA IS RANDOM MAC ADDRESS; ADD TO LOG
			[ -z "${device_log[$data]}" ] && is_new=true
			device_log["$data"]="$timestamp"

		elif [ "$cmd" == "MQTT" ]; then 
			#IN RESPONSE TO MQTT SCAN 
			determine_association

		elif [ "$cmd" == "PUBL" ]; then 
			#DATA IS PUBLIC MAC ADDRESS; ADD TO LOG
			[ -z "${device_log[$data]}" ] && is_new=true
			device_log["$data"]="$timestamp"
			manufacturer="$(determine_manufacturer $data)"

		elif [ "$cmd" == "NAME" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			mac=$(echo "$data" | awk -F "|" '{print $1}')
			name=$(echo "$data" | awk -F "|" '{print $2}')
			data="$mac"

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer $data)"

		elif [ "$cmd" == "BEAC" ]; then 
			#DATA IS DELIMITED BY VERTICAL PIPE
			uuid=$(echo "$data" | awk -F "|" '{print $1}')
			major=$(echo "$data" | awk -F "|" '{print $2}')
			minor=$(echo "$data" | awk -F "|" '{print $3}')
			rssi=$(echo "$data" | awk -F "|" '{print $4}')
			power=$(echo "$data" | awk -F "|" '{print $5}')

			#KEY DEFINED AS UUID-MAJOR-MINOR
			key="$uuid-$major-$minor"
			[ -z "${device_log[$key]}" ] && is_new=true
			device_log["$key"]="$timestamp"	

			#GET MANUFACTURER INFORMATION
			manufacturer="$(determine_manufacturer $data)"			
		fi

		#**********************************************************************
		#**********************************************************************

		#ECHO VALUES FOR DEBUGGING
		if [ "$cmd" == "NAME" ] ; then 
			
			#PRINTING FORMATING
			debug_name="$name"
			[ -z "$debug_name" ] && debug_name="${RED}[Error]${NC}"
			
			#PRINT RAW COMMAND; DEBUGGING
			echo -e "${BLUE}[CMD-$cmd]	${NC}$data ${GREEN}$debug_name${NC} $manufacturer${NC}"
		
		elif [ "$cmd" == "BEAC" ]; then 
			#PRINTING FORMATING
			debug_name="$name"
			[ -z "$debug_name" ] && debug_name="${RED}[Error]${NC}"
		
			echo -e "${BLUE}[CMD-$cmd]	${NC}$data ${GREEN}$debug_name${NC} $manufacturer${NC}"
		fi 

		if [ "$cmd" == "PUBL" ] ; then 
			echo -e "${RED}[CMD-$cmd]	${NC}$data ${NC} $manufacturer${NC} $is_new"

		elif [ "$cmd" == "RAND" ] ; then 
			echo -e "${RED}[CMD-${BLUE}$cmd${NC}]	${NC}$data ${NC} $is_new"
		fi 

	done < <(cat < main_pipe)

	#PREVENT UNNECESSARILY FAST LOOPING
	[ "$event_received" == false ] && sleep 3
done