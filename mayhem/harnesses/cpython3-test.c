/*
 * cpython3-test.c — KAT (known-answer test) oracle for mayhem/test.sh.
 *
 * Links against the installed CPython shared library (libpython3.X.so).
 * If the library is neutered (e.g. via LD_PRELOAD exit(0) in the sabotage
 * check), Py_Initialize() never runs and we never print "KAT_PASS", so
 * test.sh correctly fails — proving the oracle asserts BEHAVIOR.
 *
 * Known answers tested:
 *   1. json.loads('[1, 2, 3]') → sum == 6
 *   2. struct.unpack('>HH', b'\xde\xad\xbe\xef') → (0xdead, 0xbeef)
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    Py_Initialize();

    /* ── KAT 1: json.loads('[1, 2, 3]') → list summing to 6 ── */
    PyObject *json_mod = PyImport_ImportModule("json");
    if (!json_mod) {
        PyErr_Print();
        Py_Finalize();
        return 1;
    }
    PyObject *loads = PyObject_GetAttrString(json_mod, "loads");
    PyObject *input = PyUnicode_FromString("[1, 2, 3]");
    PyObject *result = PyObject_CallOneArg(loads, input);

    if (!result || !PyList_Check(result) || PyList_Size(result) != 3) {
        fprintf(stderr, "FAIL: json.loads returned wrong result\n");
        Py_XDECREF(result); Py_DECREF(input); Py_DECREF(loads); Py_DECREF(json_mod);
        Py_Finalize();
        return 1;
    }

    long json_sum = 0;
    for (int i = 0; i < 3; i++) {
        json_sum += PyLong_AsLong(PyList_GET_ITEM(result, i));
    }
    Py_DECREF(result); Py_DECREF(input); Py_DECREF(loads); Py_DECREF(json_mod);

    if (json_sum != 6) {
        printf("FAIL: json_sum=%ld (expected 6)\n", json_sum);
        Py_Finalize();
        return 1;
    }

    /* ── KAT 2: struct.unpack('>HH', b'\xde\xad\xbe\xef') ── */
    PyObject *struct_mod = PyImport_ImportModule("struct");
    if (!struct_mod) {
        PyErr_Print();
        Py_Finalize();
        return 1;
    }
    PyObject *unpack = PyObject_GetAttrString(struct_mod, "unpack");
    PyObject *fmt = PyUnicode_FromString(">HH");
    const char raw[] = {'\xde', '\xad', '\xbe', '\xef'};
    PyObject *data = PyBytes_FromStringAndSize(raw, 4);
    PyObject *unpacked = PyObject_CallFunctionObjArgs(unpack, fmt, data, NULL);

    if (!unpacked || !PyTuple_Check(unpacked) || PyTuple_Size(unpacked) != 2) {
        fprintf(stderr, "FAIL: struct.unpack returned wrong result\n");
        Py_XDECREF(unpacked); Py_DECREF(data); Py_DECREF(fmt);
        Py_DECREF(unpack); Py_DECREF(struct_mod);
        Py_Finalize();
        return 1;
    }

    long v0 = PyLong_AsLong(PyTuple_GET_ITEM(unpacked, 0));
    long v1 = PyLong_AsLong(PyTuple_GET_ITEM(unpacked, 1));
    Py_DECREF(unpacked); Py_DECREF(data); Py_DECREF(fmt);
    Py_DECREF(unpack); Py_DECREF(struct_mod);

    if (v0 != 0xdead || v1 != 0xbeef) {
        printf("FAIL: struct_unpack=(%lx,%lx) expected (dead,beef)\n", v0, v1);
        Py_Finalize();
        return 1;
    }

    printf("KAT_PASS: json_sum=%ld struct_unpack=(%lx,%lx)\n", json_sum, v0, v1);
    Py_Finalize();
    return 0;
}
