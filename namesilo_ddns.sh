#!/bin/bash

## Namesilo DDNS without dependences
## By Mr.Jos

## Requirements: bash; wget; ping; ping6

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

## Temp xml file to get response from Namesilo
RESPONSE="/var/tmp/namesilo_response.xml"

## Pools for request public IP address
## Emptying pool means to disable updating the corresponding DNS record (A/AAAA)
IP_POOL_V4=(
    "http://v4.ident.me"
    "https://ip4.nnev.de"
    "https://v4.ifconfig.co"
    "https://ipv4.icanhazip.com"
    "https://ipv4.wtfismyip.com/text"
)

IP_POOL_V6=(
    "http://v6.ident.me"
    "https://ip6.nnev.de"
    "https://v6.ifconfig.co"
    "https://ipv6.icanhazip.com"
    "https://ipv6.wtfismyip.com/text"
)

## If enable debug log echo
LOG_DEBUG=true

## ========= Do not edit lines below =========

RSLT_801="[801] Invalid Host Syntax"
RSLT_811="[811] Resolving failed"
RSLT_821="[821] No exist record is matched"
RSLT_850="[850] IP does not change, no need to update"

function _log_debug() { [[ -n ${LOG_DEBUG} ]] && echo "> $*"; }

function get_current_ip()
{
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
            _log_debug "Get [${VAR}] from [${IP_POOL[i]}] for IP${IP_TYPE}."
            if [[ ${VAR} =~ ${IP_PATTERN} ]]; then
                eval CUR_IP_${IP_TYPE}=${VAR}
                break
            fi
        done

        VAR="CUR_IP_${IP_TYPE}"
        if [[ -z ${!VAR} ]]; then
            _log_debug "Get IP${IP_TYPE} failed." \
                "Corresponding records (A/AAAA) will not be updated."
        fi
    done
}

function check_hosts()
{
    local IP_TYPE i
    local IP_COMMAND_V4="ping"
    local IP_COMMAND_V6="ping6"

    for i in ${!HOST[@]}; do
        STAGE[${i}]="check"
        local SECS=(${HOST[i]//./ })
        local NUM=${#SECS[@]}

        ## split host
        if [[ ${NUM} -lt 2 ]]; then
            [[ -n ${CUR_IP_V4} ]] && RESULT_V4[${i}]=${RSLT_801}
            [[ -n ${CUR_IP_V6} ]] && RESULT_V6[${i}]=${RSLT_801}
        else
            DOMAIN[${i}]="${SECS[(NUM-2)]}.${SECS[(NUM-1)]}"
            [[ ${NUM} -gt 2 ]] && RRHOST[${i}]=${HOST[i]%.${DOMAIN[i]}}
        fi
        _log_debug "Split host-${i}: [${HOST[i]}]>>[${RRHOST[i]}|${DOMAIN[i]}]"

        ## resolving check
        for IP_TYPE in V4 V6; do
            local IP_NAME="CUR_IP_${IP_TYPE}"
            [[ -z ${!IP_NAME} ]] && continue
            local VAR="RESULT_${IP_TYPE}"
            [[ -n ${!VAR} ]] && continue
            local VAR="IP_COMMAND_${IP_TYPE}"
            local RES=$( ${!VAR} -c 1 -w 1 ${HOST[i]} 2>/dev/null )
            _log_debug "Result of ${!VAR} ${HOST[i]}: [ ${RES} ]"
            if [[ -z ${RES} ]]; then
                eval RESULT_${IP_TYPE}[${i}]=${RSLT_811}
            elif [[ ${RES} == *"(${!IP_NAME})"* ]]; then
                eval RESULT_${IP_TYPE}[${i}]=${RSLT_850}
            fi
        done
    done
}

## Parse the Namesilo XML response via SAX and extract the specified values
function _parse_response()
{
    unset REQ_OPER REQ_IP REP_CODE REP_DETAIL
    unset REP_RRID REP_RRTYPE REP_RRHOST REP_RRVALUE REP_RRTTL

    _log_debug "Start parsing XML: [ $(cat ${RESPONSE}) ]"

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
                _log_debug "Value parsed: [ REP_CODE=${CONTENT} ]"
                REP_CODE=${CONTENT} ;;
                "//namesilo/reply/detail")
                _log_debug "Value parsed: [ REP_DETAIL=${CONTENT} ]"
                REP_DETAIL=${CONTENT} ;;
                "//namesilo/reply/record_id")
                _log_debug "Value parsed: [ REP_RRID=${CONTENT} ]"
                REP_RRID=${CONTENT} ;;
                "//namesilo/reply/resource_record/record_id")
                _log_debug "Value parsed: [ REP_RRID[${IDX}]=${CONTENT} ]"
                REP_RRID[${IDX}]=${CONTENT} ;;
                "//namesilo/reply/resource_record/type")
                _log_debug "Value parsed: [ REP_RRTYPE[${IDX}]=${CONTENT} ]"
                REP_RRTYPE[${IDX}]=${CONTENT} ;;
                "//namesilo/reply/resource_record/host")
                _log_debug "Value parsed: [ REP_RRHOST[${IDX}]=${CONTENT} ]"
                REP_RRHOST[${IDX}]=${CONTENT} ;;
                "//namesilo/reply/resource_record/value")
                _log_debug "Value parsed: [ REP_RRVALUE[${IDX}]=${CONTENT} ]"
                REP_RRVALUE[${IDX}]=${CONTENT} ;;
                "//namesilo/reply/resource_record/ttl")
                _log_debug "Value parsed: [ REP_RRTTL[${IDX}]=${CONTENT} ]"
                REP_RRTTL[${IDX}]=${CONTENT} ;;
            esac
        fi
    done < ${RESPONSE}

    rm -f ${RESPONSE}
}

## Match the specified hosts with the fetched response records
## @Para1: indexes of the hosts to be matched
function _match_response()
{
    local IP_TYPE i j
    local IP_RECORD_V4="A"
    local IP_RECORD_V6="AAAA"

    local DS_IDX_ITER=(${1})
    for i in ${DS_IDX_ITER[@]}; do
        STAGE[${i}]="${STAGE[i]}-->fetch"
        for IP_TYPE in V4 V6; do
            local IP_NAME="CUR_IP_${IP_TYPE}"
            [[ -z ${!IP_NAME} ]] && continue

            if [[ ${REP_CODE} -ne 300 ]]; then
                eval RESULT_${IP_TYPE}[${i}]="[${REP_CODE}] ${REP_DETAIL}"
            else
                eval RESULT_${IP_TYPE}[${i}]=${RSLT_821}
            fi
        done

        ## iter each response record with the same host
        for j in ${!REP_RRHOST[@]}; do
            [[ ${REP_RRHOST[j]} != ${HOST[i]} ]] && continue
            REP_RRHOST[${j}]=""   ## ensure this record will not be reused

            for IP_TYPE in V4 V6; do
                local VAR="IP_RECORD_${IP_TYPE}"
                [[ ${REP_RRTYPE[j]} != ${!VAR} ]] && continue
                _log_debug "Record-${j} [${!VAR}|${REP_RRID[j]}]" \
                    "matched host-${i} [${HOST[i]}]."

                eval RRID_${IP_TYPE}[${i}]=${REP_RRID[j]}
                eval RRTTL_${IP_TYPE}[${i}]=${REP_RRTTL[j]}
                eval RRVALUE_${IP_TYPE}[${i}]=${REP_RRVALUE[j]}

                local IP_NAME="CUR_IP_${IP_TYPE}"
                if [[ ${REP_RRVALUE[j]} == ${!IP_NAME} ]]; then
                    eval RESULT_${IP_TYPE}[${i}]=${RSLT_850}
                else
                    eval RESULT_${IP_TYPE}[${i}]=""
                fi
            done
        done
    done
}

function fetch_records()
{
    local DS i
    declare -A DS_IDXS DS_NUM

    ## count the number of valid host for each domain
    for i in ${!HOST[@]}; do
        DS_IDXS[${DOMAIN[i]}]+=" ${i}"
        if [[ -n ${CUR_IP_V4} && -z ${RESULT_V4[i]} ]]; then
            let DS_NUM[${DOMAIN[i]}]++
        fi
        if [[ -n ${CUR_IP_V6} && -z ${RESULT_V6[i]} ]]; then
            let DS_NUM[${DOMAIN[i]}]++
        fi
    done

    ## iter each domain with at least one host to be updated
    for DS in ${!DS_IDXS[*]}; do
        if [[ ${DS_NUM[${DS}]:-0} == 0 ]]; then
            _log_debug "Skip fetching DNS records of [${DS}]" \
                "which has no valid host."
            continue
        fi
        ## https://www.namesilo.com/api_reference.php#dnsListRecords
        local REQ="https://www.namesilo.com/api/dnsListRecords"
        REQ="${REQ}?version=1&type=xml&key=${APIKEY}&domain=${DS}"
        _log_debug "Start fetching DNS records of domain [${DS}]."
        wget -qO- ${REQ} > ${RESPONSE} 2>&1
        _parse_response
        _match_response ${DS_IDXS[${DS}]}
    done
}

function update_record()
{
    local IP_TYPE i
    local IP_RECORD_V4="A"
    local IP_RECORD_V6="AAAA"

    for i in ${!HOST[@]}; do
        local IS_UPDATED=""
        for IP_TYPE in V4 V6; do
            local VAR="RESULT_${IP_TYPE}[${i}]"
            [[ -n ${!VAR} ]] && continue
            IS_UPDATED=true

            local IP_NAME="CUR_IP_${IP_TYPE}"
            local REQ="https://www.namesilo.com/api/dnsUpdateRecord"
            REQ="${REQ}?version=1&type=xml&key=${APIKEY}&domain=${DOMAIN[i]}"
            REQ="${REQ}&rrid=${RRID[i]}&rrhost=${RRHOST[i]}"
            REQ="${REQ}&rrvalue=${!IP_NAME}&rrttl=${RRTTL[i]}"

            local VAR="IP_RECORD_${IP_TYPE}"
            _log_debug "Start updating ${!VAR} record for" \
                "host-${i} [${HOST[i]}]."
            wget -qO- ${REQ} > ${RESPONSE} 2>&1
            _parse_response

            if [[ ${REP_CODE} -eq 300 ]]; then
                eval RRID_${IP_TYPE}[${i}]=${REP_RRID}
                eval RRVALUE_${IP_TYPE}[${i}]=${!IP_NAME}
            fi
            eval RESULT_${IP_TYPE}[${i}]="[${REP_CODE}] ${REP_DETAIL}"
        done
        [[ -n ${IS_UPDATED} ]] && STAGE[${i}]="${STAGE[i]}-->update"
    done

}

function print_report()
{
    local IP_TYPE VAR
    local SEP_LINE="=================================================="
    local SUBTITLE_V4="  <----------------- A Record ----------------->  "
    local SUBTITLE_V6="  <---------------- AAAA Record --------------->  "

    echo
    echo "[Namesilo DDNS Updating Report]"
    echo "<TIME> $(date)"
    echo "<CURRENT_IPV4> ${CUR_IP_V4:-NUL}"
    echo "<CURRENT_IPV6> ${CUR_IP_V6:-NUL}"
    echo ${SEP_LINE}
    for (( i=0; i<${#HOST[@]}; i++ )); do
        echo " <HOST-${i}> ${HOST[i]}"
        echo " <STAGE> ${STAGE[i]}"
        echo " <DOMAIN> ${DOMAIN[i]:-NUL}"
        echo " <RRHOST> ${RRHOST[i]:-NUL}"
        for IP_TYPE in V4 V6; do
            local IP_NAME="CUR_IP_${IP_TYPE}"
            [[ -z ${!IP_NAME} ]] && continue
            VAR="SUBTITLE_${IP_TYPE}"; echo ${!VAR}
            VAR="RESULT_${IP_TYPE}[${i}]";  echo "  <RESULT> ${!VAR:-NUL}"
            VAR="RRID_${IP_TYPE}[${i}]";    echo "  <RRID> ${!VAR:-NUL}"
            VAR="RRVALUE_${IP_TYPE}[${i}]"; echo "  <RRVALUE> ${!VAR:-NUL}"
            VAR="RRTTL_${IP_TYPE}[${i}]";   echo "  <RRTTL> ${!VAR:-NUL}"
        done
        echo ${SEP_LINE}
    done
}

function main()
{
    get_current_ip
    check_hosts
    [[ ${HOST_COUNT} -eq 0 ]] && exit 0
    fetch_records
    [[ ${HOST_COUNT} -eq 0 ]] && exit 0
    update_records
    print_report
}

#main
exit $(( ${HOST_COUNT}+128 ))
