#!/usr/bin/env python3
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

if "HAVE_OPENSSL_ENGINE" in text:
    sys.exit(0)

text = text.replace(
    "#include <openssl/engine.h>\n",
    "#if __has_include(<openssl/engine.h>)\n"
    "# include <openssl/engine.h>\n"
    "# define HAVE_OPENSSL_ENGINE 1\n"
    "#else\n"
    "# define HAVE_OPENSSL_ENGINE 0\n"
    "#endif\n",
)

text = text.replace(
    'if (!cert_src[0]) {\n'
    '\t\t/* Invoked with no input; create empty file */',
    'if (!cert_src[0]) {\n'
    '\t\t/* Invoked with no input; create empty file */',
)

text = text.replace(
    '} else if (!strncmp(cert_src, "pkcs11:", 7)) {\n'
    '\t\tENGINE *e;',
    '} else if (!strncmp(cert_src, "pkcs11:", 7)) {\n'
    '#if HAVE_OPENSSL_ENGINE\n'
    '\t\tENGINE *e;',
)

text = text.replace(
    '\t\tERR(!parms.cert, "Get X.509 from PKCS#11");\n'
    '\t\twrite_cert(parms.cert);\n'
    '\t} else {',
    '\t\tERR(!parms.cert, "Get X.509 from PKCS#11");\n'
    '\t\twrite_cert(parms.cert);\n'
    '#else\n'
    '\t\terr(1, "OpenSSL ENGINE support is not available for PKCS#11 certificate input");\n'
    '#endif\n'
    '\t} else {',
)

path.write_text(text)
