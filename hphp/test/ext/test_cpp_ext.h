/*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | Copyright (c) 2010-2016 Facebook, Inc. (http://www.facebook.com)     |
   +----------------------------------------------------------------------+
   | This source file is subject to version 3.01 of the PHP license,      |
   | that is bundled with this package in the file LICENSE, and is        |
   | available through the world-wide-web at the following url:           |
   | http://www.php.net/license/3_01.txt                                  |
   | If you did not receive a copy of the PHP license and are unable to   |
   | obtain it through the world-wide-web, please send a note to          |
   | license@php.net so we can mail you a copy immediately.               |
   +----------------------------------------------------------------------+
*/

#ifndef incl_HPHP_TEST_CPP_EXT_H_
#define incl_HPHP_TEST_CPP_EXT_H_

#include "hphp/test/ext/test_cpp_base.h"
#include "hphp/runtime/base/builtin-functions.h"
#include "hphp/runtime/base/execution-context.h"
#include "hphp/runtime/base/program-functions.h"
#include "hphp/runtime/ext/std/ext_std_misc.h"

///////////////////////////////////////////////////////////////////////////////

/**
 * Testing CPP extension library coding.
 */
struct TestCppExt : TestCppBase {
  TestCppExt();
};

inline void evalCodeForCppExt(const String& code_str) {
  String prefixedCode = concat("<?php ", code_str);
  Unit* unit = g_context->compileEvalString(prefixedCode.get());
  TypedValue retVal;
  g_context->invokeUnit(&retVal, unit);
  tvRefcountedDecRef(&retVal);
}

#define DECLARE_TEST_FUNCTIONS(s)                                       \
  char *argv[] = { const_cast<char*>(which.c_str()), nullptr };         \
  execute_command_line_begin(1, argv, false);                           \
  evalCodeForCppExt(s);                                                 \
                                                                        \
  SCOPE_EXIT {                                                          \
    execute_command_line_end(0, false, which.c_str());                  \
  }

///////////////////////////////////////////////////////////////////////////////

#endif // incl_HPHP_TEST_CPP_EXT_H_
