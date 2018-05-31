#!/bin/bash

## Namesilo DDNS without dependences
## By Mr.Jos

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
## Emptying pool means disabling corresponding DNS record (A/AAAA) updating
POOL_IPV4=(
    "http://v4.ident.me"
    "https://ip4.nnev.de"
    "https://v4.ifconfig.co"
    "https://ipv4.icanhazip.com"
    "https://ipv4.wtfismyip.com/text"
)

POOL_IPV6=(
    "http://v6.ident.me"
    "https://ip6.nnev.de"
    "https://v6.ifconfig.co"
    "https://ipv6.icanhazip.com"
    "https://ipv6.wtfismyip.com/text"
)

## If enable debug log echo
LOG_DEBUG=true

## ========= Do not edit lines below =========

## Count of hosts which need to update
HOST_COUNT=0

RSLT_801="[801] Invalid Host Syntax"
RSLT_811="[811] IP no change, no need to update"
RSLT_821="[821] No exist A record is matched"

function _log_debug() { [[ -n ${LOG_DEBUG} ]] && echo "> $*"; }

## @Para1: "IPV4" or "IPV6"
function get_current_ip()
{
    [[ ${1} != "IPV4" && ${1} != "IPV6" ]] && return 1

    local VAR
    local PATTERN_IPV4="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    local PATTERN_IPV6="^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{1,4}$"
    VAR="PATTERN_${1}"; local PATTERN_IP=${!VAR}
    VAR="POOL_${1}[@]"; local POOL_IP=(${!VAR})

    ## get current ip from pool in random order
    local RAND=$(( ${RANDOM} % ${#POOL_IP[@]} ))
    for (( i=((${RAND}-${#POOL_IP[@]})); i<${RAND}; i++ )); do
        VAR=$( wget -qO- -t 1 -T 5 ${POOL_IP[i]} )
        _log_debug "Get [${VAR}] from [${POOL_IP[i]}]."
        if [[ ${VAR} =~ ${PATTERN_IP} ]]; then
            eval "${1}=${VAR}"
            break
        fi
    done

    VAR="${1}"; [[ -n ${!VAR} ]] && return 0
    _log_debug "Get ${1} failed. Corresponding records will not be updated."
}

function split_hosts()
{
    local SECS NUM
    for i in ${!HOST[@]}; do
        STAGE[${i}]="split"
        SECS=(${HOST[i]//./ })
        NUM=${#SECS[@]}
        if [[ ${NUM} -lt 2 ]]; then
            [[ -n ${IPV4} ]] && A1_RESULT[${i}]=${RSLT_801}
            [[ -n ${IPV6} ]] && A4_RESULT[${i}]=${RSLT_801}
        else
            DOMAIN[${i}]="${SECS[(NUM-2)]}.${SECS[(NUM-1)]}"
            [[ ${NUM} -gt 2 ]] && RRHOST[${i}]=${HOST[i]%.${DOMAIN[i]}}
        fi
        _log_debug "Split host-${i}: [${HOST[i]}]>>[${RRHOST[i]}|${DOMAIN[i]}]"
    done
}

## @Para1: "IPV4" or "IPV6"
function check_hosts()
{
    [[ ${1} != "IPV4" && ${1} != "IPV6" ]] && return 1

    local RES_STDOUT RES_STDERR
    for i in ${!HOST[@]}; do
        continue

    done
}


function check_hosts()
{
    local SECS NUM RES_PING
    for i in ${!HOST[@]}; do
        STAGE[${i}]="check"
        SECS=(${HOST[i]//./ })
        NUM=${#SECS[@]}

        ## seperate host
        if [[ ${NUM} -lt 2 ]]; then
            RESULT[${i}]=${RSLT_801}
        else
            DOMAIN[${i}]="${SECS[(NUM-2)]}.${SECS[(NUM-1)]}"
            [[ ${NUM} -gt 2 ]] && RRHOST[${i}]=${HOST[i]%.${DOMAIN[i]}}
        fi
        _log_debug "Split host-${i}: [${HOST[i]}]>>[${RRHOST[i]}|${DOMAIN[i]}]"

        ## check if the host's resolve is the same as the current ip
        if [[ -n ${GET_IP} ]]; then
            RES_PING=$( ping -c 1 ${HOST[i]} 2>&1 )
            _log_debug "Ping host-${i} result: [ ${RES_PING} ]"
            [[ ${RES_PING} == *${GET_IP}* ]] && RESULT[${i}]=${RSLT_811}
        fi

        ## add valid domain to domains list for fetching records
        [[ -n ${RESULT[i]} ]] && continue
        let HOST_COUNT++
        if [[ " ${DOMAINS[@]} " != *" ${DOMAIN[i]} "* ]]; then
            DOMAINS+=(${DOMAIN[i]})
            _log_debug "Add new domain [${DOMAIN[i]}] to fetching list."
        fi
    done
    _log_debug "At present, ${HOST_COUNT} host(s) need to update DNS record."
}

## Parse xml response from Namesilo via SAX and extract specified values
function _parse_reponse()
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
                "//namesilo/request/operation")
                _log_debug "Value parsed: [ REQ_OPER=${CONTENT} ]"
                REQ_OPER=${CONTENT} ;;
                "//namesilo/request/ip")
                _log_debug "Value parsed: [ REQ_IP=${CONTENT} ]"
                REQ_IP=${CONTENT} ;;
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

function fetch_records()
{
    local REQ_BASE REQ DOMAIN_POINTER REC_IDX
    ## https://www.namesilo.com/api_reference.php#dnsListRecords
    REQ_BASE="https://www.namesilo.com/api/dnsListRecords?version=1&type=xml"

    for DOMAIN_POINTER in ${DOMAINS[@]}; do
        REQ="${REQ_BASE}&key=${APIKEY}&domain=${DOMAIN_POINTER}"
        _log_debug "Start fetching DNS records of domain [${DOMAIN_POINTER}]."
        wget -qO- ${REQ} > ${RESPONSE} 2>&1
        _parse_reponse

        for i in ${!HOST[@]}; do
            ## skip host with unmatched domain
            [[ ${DOMAIN[i]} != ${DOMAIN_POINTER} ]] && continue
            ## skip host having rrid
            [[ -n ${RRID[i]} ]] && continue
            ## default value if fetching record failed
            RRID[${i}]=NUL

            STAGE[${i}]="${STAGE[i]}-->fetch"
            if [[ ${REP_CODE} -ne 300 ]]; then      ## request failed
                RESULT[${i}]="[${REP_CODE}] ${REP_DETAIL}"
                continue
            fi

            ## get record index with the same host
            REC_IDX=""
            for j in ${!REP_RRHOST[@]}; do
                [[ ${REP_RRTYPE[j]} != "A" ]] && continue
                [[ ${REP_RRHOST[j]} != ${HOST[i]} ]] && continue
                REC_IDX=${j}; break
            done

            ## write rrid & ttl of record with this host
            if [[ -z ${REC_IDX} ]]; then
                RESULT[${i}]=${RSLT_821}
            else
                _log_debug "Host-${i} matched record-${REC_IDX}."
                RRID[${i}]=${REP_RRID[REC_IDX]}
                RRTTL[${i}]=${REP_RRTTL[REC_IDX]}
                RRVALUE[${i}]=${REP_RRVALUE[REC_IDX]}
                REP_RRHOST[${REC_IDX}]=""  ## ensure this record won't be reused
                if [[ ${REP_RRVALUE[REC_IDX]} == ${REQ_IP} ]]; then
                    [[ -z ${RESULT[i]} ]] && let HOST_COUNT--
                    RESULT[${i}]=${RSLT_811}    ## unchanged ip won't be updated
                fi
            fi
        done
    done
    _log_debug "At present, ${HOST_COUNT} host(s) need to update DNS record."
}

function update_records()
{
    local REQ_BASE REQ
    ## https://www.namesilo.com/api_reference.php#dnsUpdateRecord
    REQ_BASE="https://www.namesilo.com/api/dnsUpdateRecord?version=1&type=xml"

    for i in ${!HOST[@]}; do
        [[ -n ${RESULT[i]} ]] && continue
        STAGE[${i}]="${STAGE[i]}-->update"

        REQ="${REQ_BASE}&key=${APIKEY}&domain=${DOMAIN[i]}&rrid=${RRID[i]}"
        REQ="${REQ}&rrhost=${RRHOST[i]}&rrvalue=${REQ_IP}&rrttl=${RRTTL[i]}"
        _log_debug "Start updating DNS record of host [${HOST[i]}]."
        wget -qO- ${REQ} > ${RESPONSE} 2>&1
        _parse_reponse

        if [[ ${REP_CODE} -eq 300 ]]; then      ## request success
            RRID[${i}]=${REP_RRID}
            RRVALUE[${i}]=${REQ_IP}
        fi
        RESULT[${i}]="[${REP_CODE}] ${REP_DETAIL}"
    done
}

function print_report()
{
    echo
    echo "[Namesilo DDNS Updating Report]"
    echo "<TIME> $(date)"
    echo "<CURRENT_IP> ${REQ_IP:-${GET_IP}}"
    echo "--------------------------------------------------"
    for (( i=0; i<${#HOST[@]}; i++ )); do
        echo " (HOST-${i}) ${HOST[i]}"
        echo " <STAGE>  ${STAGE[i]}"
        echo " <RESULT> ${RESULT[i]}"
        echo " <DETAIL> rrhost=${RRHOST[i]:-NUL}  domain=${DOMAIN[i]:-NUL}"
        echo "          rrid=${RRID[i]:-NUL}"
        echo "          rrvalue=${RRVALUE[i]:-NUL}  rrttl=${RRTTL[i]:-NUL}"
        echo "--------------------------------------------------"
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
