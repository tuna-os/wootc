/* SPDX-License-Identifier: GPL-3.0-or-later
 * Export the same PE digest used by pinned sbsigntools' signature verifier.
 * The caller validates PE bounds before invoking this helper.
 */
#include <stdint.h>
#include <stdio.h>
#include <ccan/talloc/talloc.h>
#include "image.h"
int main(int argc, char **argv)
{
    uint8_t digest[32];
    struct image *image;
    if (argc != 2)
        return 2;
    image = image_load(argv[1]);
    if (!image)
        return 1;
    if (image_hash_sha256(image, digest)) {
        talloc_free(image);
        return 1;
    }
    for (unsigned i = 0; i < sizeof(digest); i++)
        printf("%02x", digest[i]);
    putchar('\n');
    talloc_free(image);
    return 0;
}
