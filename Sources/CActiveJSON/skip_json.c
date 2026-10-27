#include <stddef.h>
#include <stdint.h>

/* Skip one opaque JSON value without decoding its conversation strings. */
size_t active_json_skip(const unsigned char *s, size_t n, size_t i) {
    while (i < n && (s[i]==' ' || s[i]=='\n' || s[i]=='\r' || s[i]=='\t')) ++i;
    if (i == n) return SIZE_MAX;
    if (s[i]=='"') {
        for (++i; i < n; ++i) {
            if (s[i]=='\\') { if (++i >= n) return SIZE_MAX; }
            else if (s[i]=='"') return i+1;
        }
        return SIZE_MAX;
    }
    if (s[i]=='{' || s[i]=='[') {
        unsigned char stack[1024]; size_t depth=0;
        do {
            unsigned char c=s[i++];
            if (c=='"') {
                int closed=0;
                while (i < n) {
                    c=s[i++];
                    if (c=='\\') { if (i >= n) return SIZE_MAX; ++i; }
                    else if (c=='"') { closed=1; break; }
                }
                if (!closed) return SIZE_MAX;
            } else if (c=='{' || c=='[') {
                if (depth==sizeof stack) return SIZE_MAX;
                stack[depth++]=c;
            } else if (c=='}' || c==']') {
                if (!depth || (c=='}' ? stack[depth-1]!='{' : stack[depth-1]!='[')) return SIZE_MAX;
                if (--depth==0) return i;
            }
        } while (i < n);
        return SIZE_MAX;
    }
    while (i < n && s[i]!=',' && s[i]!='}' && s[i]!=']' && s[i]!=' ' && s[i]!='\n' && s[i]!='\r' && s[i]!='\t') ++i;
    return i;
}
