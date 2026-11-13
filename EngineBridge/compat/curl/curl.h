// A stand-in for <curl/curl.h>, which iOS does not ship.
//
// creatica_ab.cpp uses libcurl for exactly one thing: the asynchronous lichess tablebase probe
// (ol_probe). On iOS that probe is switched off (the app sends "setoption name OnlineTablebase
// value false"), and if it ever runs anyway, curl_easy_init() returning nullptr makes ol_probe()
// report "no answer", which is the path the engine already takes on any network failure.
//
// Only the symbols creatica_ab.cpp names are defined. If the engine starts using another one, the
// build fails here rather than silently doing something different.
#ifndef CREATICA_IOS_CURL_STUB_H
#define CREATICA_IOS_CURL_STUB_H

typedef void CURL;

typedef enum { CURLE_OK = 0, CURLE_FAILED_INIT = 2 } CURLcode;

typedef enum {
    CURLOPT_URL,
    CURLOPT_HTTPGET,
    CURLOPT_WRITEFUNCTION,
    CURLOPT_WRITEDATA,
    CURLOPT_TIMEOUT_MS,
    CURLOPT_CONNECTTIMEOUT_MS
} CURLoption;

typedef enum { CURLINFO_RESPONSE_CODE } CURLINFO;

#define CURL_GLOBAL_DEFAULT 3L

static inline CURLcode curl_global_init(long) { return CURLE_OK; }
static inline void curl_global_cleanup(void) {}
static inline CURL * curl_easy_init(void) { return nullptr; }
static inline char * curl_easy_escape(CURL *, const char *, int) { return nullptr; }
static inline void curl_free(void *) {}
static inline CURLcode curl_easy_setopt(CURL *, CURLoption, ...) { return CURLE_FAILED_INIT; }
static inline CURLcode curl_easy_perform(CURL *) { return CURLE_FAILED_INIT; }
static inline CURLcode curl_easy_getinfo(CURL *, CURLINFO, ...) { return CURLE_FAILED_INIT; }

#endif
