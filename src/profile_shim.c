// Profile field accessor shim to work around Zig/C alignment issues
// This provides exported functions to access flatbuffer profile fields

#include "../nostrdb/src/bindings/c/flatbuffers_common_reader.h"
#include "../nostrdb/src/bindings/c/profile_reader.h"
#include <stddef.h>

// Export functions to access NdbProfileRecord fields
const void* ndb_profile_record_profile(const void* record) {
    if (!record) return NULL;
    // The record is actually a flatbuffer buffer, we need to get the root table
    NdbProfileRecord_table_t rec = NdbProfileRecord_as_root(record);
    if (!rec) return NULL;
    NdbProfile_table_t prof = NdbProfileRecord_profile(rec);
    return prof;
}

uint64_t ndb_profile_record_note_key(const void* record) {
    if (!record) return 0;
    NdbProfileRecord_table_t rec = NdbProfileRecord_as_root(record);
    if (!rec) return 0;
    return NdbProfileRecord_note_key(rec);
}

const char* ndb_profile_record_lnurl(const void* record) {
    if (!record) return NULL;
    NdbProfileRecord_table_t rec = NdbProfileRecord_as_root(record);
    if (!rec) return NULL;
    return NdbProfileRecord_lnurl(rec);
}

// Export functions to access NdbProfile fields
const char* ndb_profile_name(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_name(prof);
}

const char* ndb_profile_website(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_website(prof);
}

const char* ndb_profile_about(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_about(prof);
}

const char* ndb_profile_lud16(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_lud16(prof);
}

const char* ndb_profile_banner(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_banner(prof);
}

const char* ndb_profile_display_name(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_display_name(prof);
}

const char* ndb_profile_picture(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_picture(prof);
}

const char* ndb_profile_nip05(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_nip05(prof);
}

const char* ndb_profile_lud06(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_lud06(prof);
}

int ndb_profile_reactions(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_reactions(prof);
}

int32_t ndb_profile_damus_donation(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_damus_donation(prof);
}

int32_t ndb_profile_damus_donation_v2(const void* profile) {
    NdbProfile_table_t prof = (NdbProfile_table_t)profile;
    return NdbProfile_damus_donation_v2(prof);
}