#! /bin/bash

## Namesilo DDNS without dependences
##      By Mr.Jos

## Requirements:
##    (Necessary) wget or curl, cat
##    (Optional)  ping, ping6, sleep, tail

## ============ General settings =============

## Your API key of Namesilo
## https://www.namesilo.com/account_api.php
APIKEY="c40031261ee449037a4b4"

## Your domains list
HOST=(
    "yourdomain1.tld"
    "subdomain1.yourdomain1.tld"
    "subdomain2.yourdomain2.tld"
    "subdomain3.yourdomain2.tld"
)

## =========== Developer settings ============

## Script running log
LOG_PATH="/var/tmp/namesilo_ddns.log"

## Temp file to get response from Namesilo
TMP_PATH="/var/tmp/namesilo_ddns.tmp"

## Pools for request public IP address
## Unset pool means to disable updating the corresponding DNS record (A/AAAA)
IP_POOL_V4=(
    "http://v4.ident.me"
    "https://ip4.nnev.de"
    "https://v4.ifconfig.co"
    "https://ipv4.icanhazip.com"
    "https://ipv4.wtfismyip.com/text"
)
# unset IP_POOL_V4

IP_POOL_V6=(
    "http://v6.ident.me"
    "https://ip6.nnev.de"
    "https://v6.ifconfig.co"
    "https://ipv6.icanhazip.com"
    "https://ipv6.wtfismyip.com/text"
)
# unset IP_POOL_V6

## Level for echo and log
##  0-disable  1-warning  2-report  3-info  4-debug
LVL_ECHO=2
LVL_LOG=3

## Max log lines
LOG_LINES=2000

## ========= Do not edit lines below =========

function _log()
{
    local LEVEL=${1}; shift
    [[ ${LVL_ECHO} -ge ${LEVEL} ]] && echo $*
    [[ ${LVL_LOG}  -ge ${LEVEL} ]] && echo $* >> ${LOG_PATH}
}

function _prepare_script()
{
    ## check nessary requirements
    local CMD
    for CMD in cat ; do
        [[ -n $( command -v ${CMD} ) ]] && continue
        _log 1 "${CMD} does not exist. Script terminates."
        exit 1
    done

    ## check wget or curl
    if [[ -n $( command -v wget ) ]]; then
        FETCH_CMD="wget -qO-"
    elif [[ -n $( command -v curl ) ]]; then
        FETCH_CMD="curl -s"
    else
        _log 1 "Neither wget nor curl exists. Script terminates."
        exit 1
    fi

    ## control log lines
    if [[ ${LVL_LOG} -gt 0 ]]; then
        tail -n ${LOG_LINES} ${LOG_PATH} > ${TMP_PATH} 2>/dev/null
        cat ${TMP_PATH} > ${LOG_PATH}
        rm -f ${TMP_PATH}
    fi

    _log 3 "========== $(date) =========="
}

_prepare_script

RSLT_801="[801] Invalid Host Syntax"
RSLT_811="[811] Resolving failed"
RSLT_821="[821] No exist record is matched"
RSLT_850="[850] IP does not change, no need to update"

IP_RECORD_V4="A"
IP_RECORD_V6="AAAA"

function get_current_ip()
{
    _log 3 "Start running [get_current_ip]."
    local IP_TYPE VAR i
    local IP_PATTERN_V4="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    local IP_PATTERN_V6="^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{1,4}$"

    for IP_TYPE in V4 V6; do
        VAR="IP_PATTERN_${IP_TYPE}"; local IP_PATTERN=${!VAR}
        VAR="IP_POOL_${IP_TYPE}[@]"; local IP_POOL=(${!VAR})

        ## get current ip from pool in random order
        local RAND=$(( ${RANDOM} % ${#IP_POOL[@]} ))
        for (( i=((${RAND}-${#IP_POOL[@]})); i<${RAND}; i++ )); do
            VAR=$( wget -qO- -t 1 -T 5 ${IP_POOL[i]} )
            _log 4 "Fetched [${VAR}] from [${IP_POOL[i]}] for IP${IP_TYPE}."
            if [[ ${VAR} =~ ${IP_PATTERN} ]]; then
                eval CUR_IP_${IP_TYPE}='${VAR}'
                break
            fi
        done

        local IP_NAME="CUR_IP_${IP_TYPE}"
        local IP_RECORD="IP_RECORD_${IP_TYPE}"
        if [[ -z ${!IP_NAME} ]]; then
            _log 3 "Failed to get IP${IP_TYPE} address." \
                "Disable ${!IP_RECORD} records updating."
        else
            _log 3 "Successed to get IP${IP_TYPE} address." \
                "Enable ${!IP_RECORD} records updating."
        fi
    done
}

function check_hosts()
{
    _log 3 "Start running [check_hosts]."
    local IP_TYPE i
    local IP_COMMAND_V4="ping"
    local IP_COMMAND_V6="ping6"

    for i in ${!HOST[@]}; do
        STAGE[${i}]="check"
        local SECS=(${HOST[i]//./ })
        local NUM=${#SECS[@]}

        ## split host
        if [[ ${NUM} -lt 2 ]]; then
            RESULT_V4[${i}]=${RSLT_801}
            RESULT_V6[${i}]=${RSLT_801}
        else
            DOMAIN[${i}]="${SECS[(NUM-2)]}.${SECS[(NUM-1)]}"
            [[ ${NUM} -gt 2 ]] && RRHOST[${i}]=${HOST[i]%.${DOMAIN[i]}}
        fi
        _log 4 "Split host-${i}: [${HOST[i]}]>>[${RRHOST[i]}|${DOMAIN[i]}]"

        ## resolving check
        for IP_TYPE in V4 V6; do
            local IP_NAME="CUR_IP_${IP_TYPE}"; [[ -z ${!IP_NAME} ]] && continue
            local VAR="RESULT_${IP_TYPE}"; [[ -n ${!VAR} ]] && continue

            local VAR="IP_COMMAND_${IP_TYPE}"
            local RES=$( ${!VAR} -c 1 -w 1 ${HOST[i]} 2>/dev/null )
            _log 4 "Result of ${!VAR} ${HOST[i]}: [ ${RES} ]"
            if [[ -z ${RES} && -n $(command -v ${!VAR}) ]]; then
                eval RESULT_${IP_TYPE}[${i}]='${RSLT_811}'
            elif [[ ${RES} == *"(${!IP_NAME})"* ]]; then
                eval RESULT_${IP_TYPE}[${i}]='${RSLT_850}'
            fi
        done
    done
}

## Parse the Namesilo XML response via SAX and extract the specified values
function _parse_response()
{
    _log 4 "Parsing XML: [ $(cat ${TMP_PATH}) ]"
    unset REP_CODE REP_DETAIL
    unset REP_RRID REP_RRTYPE REP_RRHOST REP_RRVALUE REP_RRTTL
    local XPATH ENTITY CONTENT
    local IDX=0
    local IFS=\>

    while read -d \< ENTITY CONTENT; do
        if [[ ${ENTITY:0:1} == "?" ]]; then     ## xml declaration
            continue
        elif [[ ${ENTITY:0:1} == "/" ]]; then   ## element end event
            case ${XPATH} in
                "//namesilo/reply/resource_record")
                let IDX++ ;;
            esac
            XPATH=${XPATH%$ENTITY}
        else                                    ## element start event
            XPATH="${XPATH}/${ENTITY}"
            case ${XPATH} in
                "//namesilo/reply/code")
                _log 4 "Value parsed: [ REP_CODE=${CONTENT} ]"
                REP_CODE=${CONTENT} ;;
                "//namesilo/reply/detail")
                _log 4 "Value parsed: [ REP_DETAIL=${CONTENT} ]"
                REP_DETAIL=${CONTENT} ;;
                "//namesilo/reply/record_id")
                _log 4 "Value parsed: [ REP_RRID=${CONTENT} ]"
                REP_RRID=${CONTENT} ;;
                "//namesilo/reply/resource_record/record_id")
                _log 4 "Value parsed: [ REP_RRID[${IDX}]=${CONTENT} ]"
                REP_RRID[${IDX}]=${CONTENT} ;;
                "//namesilo/reply/resource_record/type")
                _log 4 "Value parsed: [ REP_RRTYPE[${IDX}]=${CONTENT} ]"
                REP_RRTYPE[${IDX}]=${CONTENT} ;;
                "//namesilo/reply/resource_record/host")
                _log 4 "Value parsed: [ REP_RRHOST[${IDX}]=${CONTENT} ]"
                REP_RRHOST[${IDX}]=${CONTENT} ;;
                "//namesilo/reply/resource_record/value")
                _log 4 "Value parsed: [ REP_RRVALUE[${IDX}]=${CONTENT} ]"
                REP_RRVALUE[${IDX}]=${CONTENT} ;;
                "//namesilo/reply/resource_record/ttl")
                _log 4 "Value parsed: [ REP_RRTTL[${IDX}]=${CONTENT} ]"
                REP_RRTTL[${IDX}]=${CONTENT} ;;
            esac
        fi
    done < ${TMP_PATH}

    rm -f ${TMP_PATH}
}

## Match the specified hosts with the fetched response records
## @Params: indexes of the hosts to be matched
function _match_response()
{
    _log 4 "Matching host indexes [$@ ]."
    local IP_TYPE i j
    for i in $@; do
        STAGE[${i}]="${STAGE[i]}-->fetch"
        if [[ ${REP_CODE} -ne 300 ]]; then
            RESULT_V4[${i}]="[${REP_CODE}] ${REP_DETAIL}"
            RESULT_V6[${i}]="[${REP_CODE}] ${REP_DETAIL}"
            continue
        fi

        RESULT_V4[${i}]=${RSLT_821}
        RESULT_V6[${i}]=${RSLT_821}
        for j in ${!REP_RRHOST[@]}; do
            [[ ${REP_RRHOST[j]} != ${HOST[i]} ]] && continue
            REP_RRHOST[${j}]=""   ## ensure this record will not be reused
            for IP_TYPE in V4 V6; do
                local VAR="IP_RECORD_${IP_TYPE}"
                [[ ${REP_RRTYPE[j]} != ${!VAR} ]] && continue
                _log 4 "Record-${j} [${REP_RRID[j]}|${!VAR}]" \
                    "matched host-${i} [${HOST[i]}]."

                eval RRID_${IP_TYPE}[${i}]='${REP_RRID[j]}'
                eval RRTTL_${IP_TYPE}[${i}]='${REP_RRTTL[j]}'
                eval RRVALUE_${IP_TYPE}[${i}]='${REP_RRVALUE[j]}'

                local VAR="CUR_IP_${IP_TYPE}"
                if [[ ${REP_RRVALUE[j]} == ${!VAR} ]]; then
                    eval RESULT_${IP_TYPE}[${i}]='${RSLT_850}'
                else
                    eval RESULT_${IP_TYPE}[${i}]=''
                fi
            done
        done
    done
}

function fetch_records()
{
    _log 3 "Start running [fetch_records]."
    local DS i
    declare -A DS_IDXS DS_NUM

    ## count the number of valid host for each domain
    for i in ${!HOST[@]}; do
        [[ -z ${DOMAIN[i]} ]] && continue
        DS_IDXS[${DOMAIN[i]}]+=" ${i}"
        if [[ -n ${CUR_IP_V4} && -z ${RESULT_V4[i]} ]]; then
            let DS_NUM[${DOMAIN[i]}]++
        fi
        if [[ -n ${CUR_IP_V6} && -z ${RESULT_V6[i]} ]]; then
            let DS_NUM[${DOMAIN[i]}]++
        fi
    done

    ## iter each domain with at least one host to be updated
    for DS in ${!DS_NUM[*]}; do
        _log 4 "Valid host number of domain [${DS}]: [${DS_NUM[${DS}]:-0}]."
        if [[ ${DS_NUM[${DS}]:-0} == 0 ]]; then
            _log 4 "Skip fetching DNS records of domain [${DS}]."
            continue
        fi
        ## https://www.namesilo.com/api_reference.php#dnsListRecords
        local REQ="https://www.namesilo.com/api/dnsListRecords"
        REQ="${REQ}?version=1&type=xml&domain=${DS}"
        _log 4 "Request of records fetching: [ ${REQ} ]"
        ${FETCH_CMD} "${REQ}&key=${APIKEY}" > ${TMP_PATH} 2>&1
        _parse_response
        _match_response ${DS_IDXS[${DS}]}
        [[ -n $( command -v sleep ) ]] && sleep 5
    done
}

function update_records()
{
    _log 3 "Start running [update_records]."
    local IP_TYPE i
    for i in ${!HOST[@]}; do
        for IP_TYPE in V4 V6; do
            local IP_NAME="CUR_IP_${IP_TYPE}"; [[ -z ${!IP_NAME} ]] && continue
            local VAR="RESULT_${IP_TYPE}[${i}]"; [[ -n ${!VAR} ]] && continue

            ## https://www.namesilo.com/api_reference.php#dnsUpdateRecord
            local REQ="https://www.namesilo.com/api/dnsUpdateRecord"
            REQ="${REQ}?version=1&type=xml&domain=${DOMAIN[i]}"
            REQ="${REQ}&rrhost=${RRHOST[i]}&rrvalue=${!IP_NAME}"
            VAR="RRID_${IP_TYPE}[${i}]" ; REQ="${REQ}&rrid=${!VAR}"
            VAR="RRTTL_${IP_TYPE}[${i}]"; REQ="${REQ}&rrttl=${!VAR}"

            VAR="IP_RECORD_${IP_TYPE}"
            STAGE[${i}]="${STAGE[i]}-->update(${!VAR})"
            _log 4 "Request of record updating [${HOST[i]}|${!VAR}]: [ ${REQ} ]"
            ${FETCH_CMD} "${REQ}&key=${APIKEY}" > ${TMP_PATH} 2>&1
            _parse_response

            if [[ ${REP_CODE} -eq 300 ]]; then
                eval RRID_${IP_TYPE}[${i}]='${REP_RRID}'
            fi
            eval RESULT_${IP_TYPE}[${i}]='"[${REP_CODE}] ${REP_DETAIL}"'
            let UPDATE_COUNT++
            [[ -n $( command -v sleep ) ]] && sleep 5
        done
    done
    _log 3 "Handled ${UPDATE_COUNT:-0} record update(s) in total."
}

function print_report()
{
    _log 3
    local IP_TYPE VAR
    local SEP_LINE="=================================================="
    local SUBTITLE_V4="  -------------- A Record --------------"
    local SUBTITLE_V6="  ------------- AAAA Record ------------"

    function _log_if_valid() { [[ -n ${!1} ]] && _log 2 "${2}${!1}" ; }

    _log 2 "[Namesilo DDNS Updating Report]"
    _log 2 "<TIME> $(date)"
    _log 2 "<UPDATE_COUNT> ${UPDATE_COUNT:-0}"
    _log 2 "<CURRENT_IPV4> ${CUR_IP_V4:-NUL}"
    _log 2 "<CURRENT_IPV6> ${CUR_IP_V6:-NUL}"
    _log 2 ${SEP_LINE}
    for (( i=0; i<${#HOST[@]}; i++ )); do
        _log 2 " <HOST-${i}> ${HOST[i]}"
        _log 2 " <STAGE>  ${STAGE[i]}"
        _log_if_valid "DOMAIN[${i}]" " <DOMAIN> "
        _log_if_valid "RRHOST[${i}]" " <SUBDOMAIN> "
        for IP_TYPE in V4 V6; do
            local IP_NAME="CUR_IP_${IP_TYPE}"; [[ -z ${!IP_NAME} ]] && continue
            _log_if_valid "SUBTITLE_${IP_TYPE}"
            _log_if_valid "RESULT_${IP_TYPE}[${i}]"  "  <RESULT> "
            _log_if_valid "RRID_${IP_TYPE}[${i}]"    "  <RRID> "
            _log_if_valid "RRTTL_${IP_TYPE}[${i}]"   "  <TTL>  "
            local VAR="RRVALUE_${IP_TYPE}[${i}]"
            if [[ -n ${!VAR} && ${!VAR} != ${!IP_NAME} ]]; then
                _log 2 "  <OLD_IP> ${!VAR}"
            fi
        done
        _log 2 ${SEP_LINE}
    done
}

function main()
{
    get_current_ip
    check_hosts
    fetch_records
    update_records
    print_report
    if [[ ${UPDATE_COUNT} -gt 0 ]]; then
        exit $(( ${UPDATE_COUNT}+128 ))
    else
        exit 0
    fi
}

main
