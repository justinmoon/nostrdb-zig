#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nostrdb/src/nostrdb.h"

int main() {
    // Allocate buffer with malloc, just like nostrdb-rs
    size_t bufsize = 1024 * 16;
    unsigned char *buffer = (unsigned char *)malloc(bufsize);
    if (!buffer) {
        printf("Failed to allocate buffer\n");
        return 1;
    }
    
    // Initialize builder
    struct ndb_builder builder;
    if (!ndb_builder_init(&builder, buffer, bufsize)) {
        printf("Failed to init builder\n");
        free(buffer);
        return 1;
    }
    
    // Set content
    const char *content = "hello world";
    if (!ndb_builder_set_content(&builder, content, strlen(content))) {
        printf("Failed to set content\n");
        free(buffer);
        return 1;
    }
    
    // Set kind
    ndb_builder_set_kind(&builder, 1);
    
    // Create keypair for signing
    struct ndb_keypair keypair;
    if (!ndb_create_keypair(&keypair)) {
        printf("Failed to create keypair\n");
        free(buffer);
        return 1;
    }
    
    // Finalize with signing
    struct ndb_note *note = NULL;
    int ok = ndb_builder_finalize(&builder, &note, &keypair);
    
    if (!ok) {
        printf("Failed to finalize note\n");
        free(buffer);
        return 1;
    }
    
    printf("Success! Note created with kind: %d\n", ndb_note_kind(note));
    printf("Content: %s\n", ndb_note_content(note));
    
    free(buffer);
    return 0;
}