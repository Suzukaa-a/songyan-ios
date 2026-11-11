#include "songyan_script.h"

#include <stdio.h>
#include <string.h>

/* Built with -DSONGYAN_SCRIPT_TESTING: forces allocation failures and counts live allocations, so
 * the parser's failure paths are exercised through the public API instead of by reading source. */
void songyan_script_test_set_allocation_failure(long fail_after);
long songyan_script_test_live_allocations(void);

static int failures = 0;

static void expect(int condition, const char *description) {
    if (condition) {
        printf("ok %s\n", description);
        return;
    }
    printf("FAIL %s\n", description);
    failures++;
}

static int header_is_zeroed(const songyan_script_header *header) {
    return header->api == 0 && header->name == NULL && header->description == NULL &&
           header->connects == NULL && header->connect_count == 0 && header->settings == NULL &&
           header->setting_count == 0 && header->secrets == NULL && header->secret_count == 0 &&
           header->needs == 0;
}

static const char *const kSource = "// @api 1\n"
                                   "// @name 分配失败\n"
                                   "// @description 一段说明\n"
                                   "// @connect api.example.com\n"
                                   "// @connect cdn.example.com\n"
                                   "// @setting endpoint url 服务地址\n"
                                   "// @setting tone choice 语气\n"
                                   "// @setting note text 备注\n"
                                   "// @secret key 密钥\n"
                                   "export default async ({ text }) => text;\n";

int main(void) {
    long baseline = songyan_script_test_live_allocations();

    /* A complete parse must leave exactly what it allocated, and the caller frees it back. */
    songyan_script_test_set_allocation_failure(-1);
    {
        songyan_script_header header;
        songyan_script_header_error error;
        songyan_script_error code =
            songyan_script_header_parse(kSource, strlen(kSource), &header, &error);
        expect(code == SONGYAN_SCRIPT_OK, "complete header is accepted");
        expect(songyan_script_test_live_allocations() > baseline, "accepted header owns memory");
        songyan_script_header_free(&header);
        expect(songyan_script_test_live_allocations() == baseline, "free releases everything");
    }

    /* Fail every allocation in turn: the parse must fail cleanly, leave a zeroed header and leak
     * nothing, including a setting whose key was allocated before its label failed. */
    long examined = 0;
    for (long fail_after = 0; fail_after < 128; fail_after++) {
        songyan_script_test_set_allocation_failure(fail_after);
        songyan_script_header header;
        songyan_script_header_error error;
        songyan_script_error code =
            songyan_script_header_parse(kSource, strlen(kSource), &header, &error);
        examined++;
        if (code == SONGYAN_SCRIPT_OK) {
            songyan_script_header_free(&header);
            break;
        }
        expect(code == SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, "allocation failure is reported as out of memory");
        expect(header_is_zeroed(&header), "failed parse leaves a zeroed header");
        expect(songyan_script_test_live_allocations() == baseline, "failed parse leaks nothing");
    }
    expect(examined > 1, "allocation failure points were swept");

    songyan_script_test_set_allocation_failure(-1);

    /* External-input boundaries through the same public entry point. */
    {
        const char with_nul[] = "// @api 1\n// @name ab\0cd\n";
        songyan_script_header header;
        songyan_script_header_error error;
        songyan_script_error code = songyan_script_header_parse(with_nul, sizeof(with_nul) - 1, &header, &error);
        expect(code == SONGYAN_SCRIPT_ERROR_HEADER, "embedded NUL is a broken header");
        expect(error.line == 2, "embedded NUL reports its line");
        expect(strcmp(error.message, "NUL byte in source") == 0, "embedded NUL names the problem");

        const char bad_utf8[] = "// @api 1\n// @name \xC3\x28\n";
        code = songyan_script_header_parse(bad_utf8, sizeof(bad_utf8) - 1, &header, &error);
        expect(code == SONGYAN_SCRIPT_ERROR_HEADER, "invalid UTF-8 is a broken header");
        expect(error.line == 2, "invalid UTF-8 reports its line");
        expect(strcmp(error.message, "invalid UTF-8") == 0, "invalid UTF-8 names the problem");
    }

    /* A BOM is an editor marker, not a declaration, and must not hide the header. */
    {
        const char with_bom[] = "\xEF\xBB\xBF// @api 1\n// @name 带 BOM\nexport default async () => 1;\n";
        songyan_script_header header;
        songyan_script_header_error error;
        songyan_script_error code =
            songyan_script_header_parse(with_bom, sizeof(with_bom) - 1, &header, &error);
        expect(code == SONGYAN_SCRIPT_OK, "UTF-8 BOM before the header is accepted");
        expect(code == SONGYAN_SCRIPT_OK && header.name != NULL &&
                   strcmp(header.name, "带 BOM") == 0,
               "BOM does not shift the header");
        songyan_script_header_free(&header);
    }

    /* A version token the user could not have meant to compare is reported without a clipped
     * number; a representable one is echoed exactly. */
    {
        const char huge[] = "// @api 12345678901234567890123456789\n// @name 太大\n";
        songyan_script_header header;
        songyan_script_header_error error;
        songyan_script_error code = songyan_script_header_parse(huge, sizeof(huge) - 1, &header, &error);
        expect(code == SONGYAN_SCRIPT_ERROR_API_VERSION, "oversized @api is refused");
        expect(strcmp(error.message,
                      "unsupported @api (number too large); this host implements 1") == 0,
               "oversized @api names the overflow, not a clipped number");
        expect(strstr(error.message, "1234567") == NULL, "oversized @api does not echo digits");
    }
    {
        const char large[] = "// @api 4294967297\n// @name 编号很大\n";
        songyan_script_header header;
        songyan_script_header_error error;
        songyan_script_error code = songyan_script_header_parse(large, sizeof(large) - 1, &header, &error);
        expect(code == SONGYAN_SCRIPT_ERROR_API_VERSION, "representable newer @api is refused");
        expect(strcmp(error.message, "unsupported @api 4294967297; this host implements 1") == 0,
               "representable newer @api is echoed exactly");
    }

    printf("boundary tests: %d failed\n", failures);
    return failures == 0 ? 0 : 1;
}
