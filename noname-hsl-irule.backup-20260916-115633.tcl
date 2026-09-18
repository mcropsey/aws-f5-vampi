proc payloadExceedsMaxSize { nn_content_length nn_payload_max_size } {
    if { ($nn_content_length ne "") && ([catch {expr {$nn_content_length > $nn_payload_max_size}}] == 0) && ($nn_content_length > $nn_payload_max_size) } {
        return true
    }
    return false
}

proc shouldFilterFromNoname nn_host {
    set nn_filtered_hosts {}

    if { [llength $nn_filtered_hosts] == 0 } {
        return false
    }

    set nn_host [string tolower [lindex [split $nn_host ":"] 0]]

    foreach nn_h $nn_filtered_hosts {
        if { [string match $nn_h $nn_host] } {
            return true
        }
    }

    return false
}

proc hasResponded nn_major_version {
    if { [expr {$nn_major_version >= "14" }] } {
        if { [catch {HTTP::has_responded} result] == 0 && $result } {
            log local0.info "Noname: HTTP Request has already responded, skipping processing"
            return true
        }
    }
    return false
}

proc logInDebug { msg } {
    set nn_debug_mode false

    if {$nn_debug_mode} {
        log local0.debug "$msg"
    }
}

proc fetchIP ip {
    if {[string first "%" $ip] != -1} {
        return [lindex [split $ip "%"] 0]
    } else {
        return $ip
    }
}

proc isStreamingContent {} {
    if {[HTTP::header exists "Content-Type"]} {
        set content_type [string tolower [HTTP::header "Content-Type"]]
        if {[string match "*stream*" $content_type]} {
            return true
        }
    }
    if {[HTTP::header exists "Transfer-Encoding"]} {
        # Trim whitespace for better edge case handling
        set transfer_encoding [string trim [string tolower [HTTP::header "Transfer-Encoding"]]]
        if {[string match "*chunked*" $transfer_encoding]} {
            return true
        }
    }
    return false
}

proc buildPayload { source_type source_index source_key source_version src_ip dst_ip src_port dst_port http_version req_timestamp req_method req_url req_headers req_body res_timestamp res_status res_headers res_body integration_type metadata } {
    return "$source_type#$source_index#$source_key#$source_version#$src_ip#$dst_ip#$src_port#$dst_port#$http_version#$req_timestamp#$req_method#$req_url#$req_headers#$req_body#$res_timestamp#$res_status#$res_headers#$res_body#$integration_type#$metadata"
}

when RULE_INIT {
    # Noname constants - calculated once at iRule load for CMP efficiency
    set static::nn_1789519311072_base64_source_type [b64encode 13]
    set static::nn_1789519311072_base64_source_index [b64encode 2]
    set static::nn_1789519311072_base64_source_key [b64encode "a50f0de7-780c-4cc2-82cd-0bc2b95d4405"]
    set static::nn_1789519311072_base64_source_version [b64encode "8.0.0"]
    set static::nn_1789519311072_integration_type [b64encode "F5_IRULE"]
    set static::nn_1789519311072_engine_hostname "10.0.8.100"
    set static::nn_1789519311072_payload_max_size 131072
    set static::nn_1789519311072_engine_url "/engine?message-format=base64"
}

when CLIENT_ACCEPTED {
    set nn_pool noname-security-hsl-https
    
    # Validate pool exists and open HSL connection with error handling
    if { [catch {HSL::open -proto TCP -pool $nn_pool} nn_hsl] } {
        log local0.error "Noname: Failed to open HSL pool '$nn_pool': $nn_hsl"
        set nn_hsl_available false
        return
    }
    set nn_hsl_available true
    
    set nn_version_sections [split $static::tcl_platform(osVersion) "."]
    set nn_major_version [lindex $nn_version_sections 0]
}

when HTTP_REQUEST {
    # Early exit if HSL not available
    if { ![info exists nn_hsl_available] || !$nn_hsl_available } {
        return
    }

    call logInDebug "\[Noname Debug\] HTTP_REQUEST - iRule executed"

    # A variable that determines whether the iRule should keep running in HTTP_RESPONSE
    set nn_run_on_response false

    if { [call hasResponded $nn_major_version] } {
        return
    }

    if { [call shouldFilterFromNoname [HTTP::host]] } {
        call logInDebug "\[Noname Debug\] HTTP_REQUEST - host filtered, skipping"
        return
    }

    # Skip payload collection if payload exceeds max size, Content-Type contains "stream", or Transfer-Encoding is "chunked"
    if { [call payloadExceedsMaxSize [HTTP::header "Content-Length"] $static::nn_1789519311072_payload_max_size] } {
        call logInDebug "\[Noname Debug\] HTTP_REQUEST - payload exceeds max size, skipping body collection"
        set nn_skip_request_payload true
    } elseif { [call isStreamingContent] } {
        call logInDebug "\[Noname Debug\] HTTP_REQUEST - skipping payload collection for streaming/chunked content"
        set nn_skip_request_payload true
    } else {
        set nn_skip_request_payload false
    }

    set nn_run_on_response true

    # Encode connection data
    set nn_base64_src_ip [b64encode [call fetchIP [IP::client_addr]]]
    set nn_base64_dst_ip [b64encode [call fetchIP [IP::local_addr]]]
    set nn_base64_src_port [b64encode [TCP::client_port]]
    set nn_base64_dst_port [b64encode [TCP::local_port]]

    # Request-specific encoding
    if { [catch { set http_ver [HTTP::version] } ver_error] } {
        set http_ver "1.1"
    }
    set nn_base64_http_version [b64encode $http_ver]
    set nn_base64_req_timestamp [b64encode [expr { [clock seconds] * 1000 }]]
    set nn_base64_req_method [b64encode [HTTP::method]]
    set nn_base64_req_url [b64encode [HTTP::uri]]
    set nn_req_content_length 0
    set nn_req_body ""

    # Build headers using list + join (O(n) instead of O(n^2))
    set nn_req_headers_list {}

    foreach nn_aHeader [lsort -unique [HTTP::header names]] {
        # Get first value only (backend doesn't support multiple values)
        set nn_value [HTTP::header $nn_aHeader]
        lappend nn_req_headers_list "$nn_aHeader:$nn_value"
    }

    # O(n) join instead of O(n^2) append
    set nn_req_headers [join $nn_req_headers_list "~~~"]
    set nn_req_headers [b64encode $nn_req_headers]

    # Request content length with validation
    if {[HTTP::header exists "Content-Length"] && [HTTP::header "Content-Length"] ne ""} {
        if { [catch {set nn_req_content_length [HTTP::header "Content-Length"]}] } {
            set nn_req_content_length 0
        }
        # Trim whitespace (RFC 7230 allows OWS around header values)
        set nn_req_content_length [string trim $nn_req_content_length]
        # Validate Content-Length is numeric before comparison
        if { ![string is integer -strict $nn_req_content_length] || $nn_req_content_length < 0 } {
            log local0.warning "Noname: Invalid Content-Length header in request: $nn_req_content_length"
            set nn_req_content_length 0
        }
    } else {
        set nn_req_content_length 0
    }

    # Collect request body if needed
    if { !$nn_skip_request_payload && $nn_req_content_length > 0 } {
        if { [catch { HTTP::collect $nn_req_content_length } collect_error] } {
            log local0.warning "Noname: HTTP::collect failed in HTTP_REQUEST: $collect_error"
        }
    }
}

when HTTP_REQUEST_DATA {
    # Early exit checks
    if { ![info exists nn_hsl_available] || !$nn_hsl_available } {
        return
    }

    # Only process if not skipping request payload
    if { [info exists nn_skip_request_payload] && $nn_skip_request_payload } {
        call logInDebug "\[Noname Debug\] HTTP_REQUEST_DATA - skipping for streaming/chunked content"
        return
    }

    call logInDebug "\[Noname Debug\] HTTP_REQUEST_DATA - identified Request body"

    # Encode request body
    if { [catch {
        set nn_req_body [b64encode [HTTP::payload]]
    } body_error] } {
        log local0.warning "Noname: Failed to encode request body: $body_error"
        set nn_req_body ""
    }

    # Release HTTP collected data (may be redundant as no subsequent HTTP::collect is issued)
    # See: https://clouddocs.f5.com/api/irules/HTTP__release.html
    HTTP::release
}

when HTTP_RESPONSE {
    # Early exit checks
    if { ![info exists nn_hsl_available] || !$nn_hsl_available } {
        return
    }
    
    call logInDebug "\[Noname Debug\] HTTP_RESPONSE - executed on Response"

    # Stop running if HTTP_REQUEST didn't run properly
    if { ![info exists nn_run_on_response] || !$nn_run_on_response } {
        return
    }

    if { [call payloadExceedsMaxSize [HTTP::header "Content-Length"] $static::nn_1789519311072_payload_max_size] } {
        call logInDebug "\[Noname Debug\] HTTP_RESPONSE - payload exceeds max size, skipping body collection"
        set nn_skip_response_payload true
    } elseif { [call isStreamingContent] } {
        call logInDebug "\[Noname Debug\] HTTP_RESPONSE - skipping payload collection for streaming/chunked content"
        set nn_skip_response_payload true
    } else {
        set nn_skip_response_payload false
    }

    # Noname metadata enrichment with error handling
    if { [catch {
        set partitionName [URI::path [virtual name]]
        if { [string index $partitionName 0] eq "/" } {
            set partitionName [string range $partitionName 1 end]
        }
        if { [string index $partitionName end] eq "/" } {
            set partitionName [string range $partitionName 0 [expr {[string length $partitionName] - 2}]]
        }

        set nn_metadata "virtualServer:[URI::basename [virtual name]]~~~"
        append nn_metadata "partition:$partitionName~~~"
        append nn_metadata "hostname:$static::tcl_platform(machine)~~~"
        append nn_metadata "version:$static::tcl_platform(osVersion)"
        set nn_metadata [b64encode $nn_metadata]
    } metadata_error] } {
        log local0.warning "Noname: Failed to build metadata: $metadata_error"
        set nn_metadata [b64encode "error:metadata_collection_failed"]
    }

    # Response information
    set nn_base64_res_timestamp [b64encode [expr { [clock seconds] * 1000 }]]
    set nn_base64_res_status [b64encode [HTTP::status]]
    set nn_res_content_length 0
    set nn_res_body ""

    # Build response headers using list + join (O(n))
    set nn_res_headers_list {}

    foreach nn_aHeader [lsort -unique [HTTP::header names]] {
        # Get first value only (backend doesn't support multiple values)
        set nn_value [HTTP::header $nn_aHeader]
        lappend nn_res_headers_list "$nn_aHeader:$nn_value"
    }

    set nn_res_headers [join $nn_res_headers_list "~~~"]
    set nn_res_headers [b64encode $nn_res_headers]

    # Response content length with validation
    if {[HTTP::header exists "Content-Length"] && [HTTP::header "Content-Length"] ne ""} {
        if { [catch {set nn_res_content_length [HTTP::header "Content-Length"]}] } {
            set nn_res_content_length 0
        }
        # Trim whitespace (RFC 7230 allows OWS around header values)
        set nn_res_content_length [string trim $nn_res_content_length]
        # Validate Content-Length is numeric before comparison
        if { ![string is integer -strict $nn_res_content_length] || $nn_res_content_length < 0 } {
            log local0.warning "Noname: Invalid Content-Length header in response: $nn_res_content_length"
            set nn_res_content_length 0
        }
    } else {
        set nn_res_content_length 0
    }

    # Collect response body if needed
    if { !$nn_skip_response_payload && $nn_res_content_length > 0 } {
        if { [catch { HTTP::collect $nn_res_content_length } collect_error] } {
            log local0.warning "Noname: HTTP::collect failed in HTTP_RESPONSE: $collect_error"
        }
    } else {
        # Build reason for skipping body collection
        set skip_reason "no body"
        if { $nn_res_content_length > $static::nn_1789519311072_payload_max_size } {
            set skip_reason "payload exceeds max size"
        } elseif { [info exists nn_skip_response_payload] && $nn_skip_response_payload } {
            set skip_reason "streaming/chunked content"
        }

        set nn_payload [call buildPayload $static::nn_1789519311072_base64_source_type $static::nn_1789519311072_base64_source_index $static::nn_1789519311072_base64_source_key $static::nn_1789519311072_base64_source_version $nn_base64_src_ip $nn_base64_dst_ip $nn_base64_src_port $nn_base64_dst_port $nn_base64_http_version $nn_base64_req_timestamp $nn_base64_req_method $nn_base64_req_url $nn_req_headers $nn_req_body $nn_base64_res_timestamp $nn_base64_res_status $nn_res_headers $nn_res_body $static::nn_1789519311072_integration_type $nn_metadata]

        # Send to Noname
        call logInDebug "\[Noname Debug\] HTTP_RESPONSE - skipping response body ($skip_reason), sending data to Engine VS"

        # Validate HSL handle before sending
        if { [info exists nn_hsl] && $nn_hsl ne "" } {
            if { [catch {
                HSL::send $nn_hsl "POST $static::nn_1789519311072_engine_url HTTP/1.1\r\nConnection: keep-alive\r\nHost: $static::nn_1789519311072_engine_hostname\r\nContent-Type: text/plain\r\nContent-Length: [string length $nn_payload]\r\n\r\n$nn_payload"
            } send_error] } {
                log local0.error "Noname: Failed to send data to HSL: $send_error"
            }
        } else {
            log local0.error "Noname: HSL handle not available, skipping send"
        }

        # Clean up all variables
        unset -nocomplain nn_req_body nn_payload
        unset -nocomplain nn_base64_src_ip nn_base64_dst_ip nn_base64_src_port nn_base64_dst_port
        unset -nocomplain nn_base64_http_version nn_base64_req_timestamp nn_base64_req_method nn_base64_req_url
        unset -nocomplain nn_req_headers nn_res_headers nn_req_content_length nn_res_content_length
        unset -nocomplain nn_base64_res_timestamp nn_base64_res_status nn_metadata
        unset -nocomplain nn_skip_request_payload nn_skip_response_payload nn_run_on_response
        unset -nocomplain nn_req_headers_list nn_res_headers_list skip_reason
    }
}

when HTTP_RESPONSE_DATA {
    # Early exit checks
    if { ![info exists nn_hsl_available] || !$nn_hsl_available } {
        return
    }

    # Only process if not skipping response payload
    if { [info exists nn_skip_response_payload] && $nn_skip_response_payload } {
        call logInDebug "\[Noname Debug\] HTTP_RESPONSE_DATA - skipping for streaming/chunked content"
        return
    }

    call logInDebug "\[Noname Debug\] HTTP_RESPONSE_DATA - identified Response body"

    # Encode response body
    if { [catch {
        set nn_res_body [b64encode [HTTP::payload]]
    } body_error] } {
        log local0.warning "Noname: Failed to encode response body: $body_error"
        set nn_res_body ""
    }

    # Update timestamp for response data
    set nn_base64_res_timestamp [b64encode [expr { [clock seconds] * 1000 }]]

    set nn_payload [call buildPayload $static::nn_1789519311072_base64_source_type $static::nn_1789519311072_base64_source_index $static::nn_1789519311072_base64_source_key $static::nn_1789519311072_base64_source_version $nn_base64_src_ip $nn_base64_dst_ip $nn_base64_src_port $nn_base64_dst_port $nn_base64_http_version $nn_base64_req_timestamp $nn_base64_req_method $nn_base64_req_url $nn_req_headers $nn_req_body $nn_base64_res_timestamp $nn_base64_res_status $nn_res_headers $nn_res_body $static::nn_1789519311072_integration_type $nn_metadata]

    # Send to Noname with error handling
    call logInDebug "\[Noname Debug\] HTTP_RESPONSE_DATA - sending data to Engine VS"

    if { [info exists nn_hsl] && $nn_hsl ne "" } {
        if { [catch {
            HSL::send $nn_hsl "POST $static::nn_1789519311072_engine_url HTTP/1.1\r\nConnection: keep-alive\r\nHost: $static::nn_1789519311072_engine_hostname\r\nContent-Type: text/plain\r\nContent-Length: [string length $nn_payload]\r\n\r\n$nn_payload"
        } send_error] } {
            log local0.error "Noname: Failed to send data to HSL: $send_error"
        }
    } else {
        log local0.error "Noname: HSL handle not available, skipping send"
    }

    # Release HTTP collected data (may be redundant as no subsequent HTTP::collect is issued)
    # See: https://clouddocs.f5.com/api/irules/HTTP__release.html
    HTTP::release

    # Clean up all variables to free memory
    unset -nocomplain nn_req_body nn_res_body nn_payload
    unset -nocomplain nn_base64_src_ip nn_base64_dst_ip nn_base64_src_port nn_base64_dst_port
    unset -nocomplain nn_base64_http_version nn_base64_req_timestamp nn_base64_req_method nn_base64_req_url
    unset -nocomplain nn_req_headers nn_res_headers nn_req_content_length nn_res_content_length
    unset -nocomplain nn_base64_res_timestamp nn_base64_res_status nn_metadata
    unset -nocomplain nn_skip_request_payload nn_skip_response_payload nn_run_on_response
    unset -nocomplain nn_req_headers_list nn_res_headers_list
}
