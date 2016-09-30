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

#include "hphp/runtime/vm/vm-regs.h"

#include "hphp/runtime/vm/jit/fixup.h"

namespace HPHP {

///////////////////////////////////////////////////////////////////////////////

// Register dirtiness: thread-private.
__thread VMRegState tl_regState = VMRegState::CLEAN;

VMRegAnchor::VMRegAnchor()
  : m_old(tl_regState)
{
  assert_native_stack_aligned();
  jit::syncVMRegs();
}

VMRegAnchor::VMRegAnchor(ActRec* ar)
  : m_old(tl_regState)
{
  assert(tl_regState == VMRegState::DIRTY);
  tl_regState = VMRegState::CLEAN;

  auto prevAr = g_context->getOuterVMFrame(ar);
  const Func* prevF = prevAr->m_func;
  assert(!ar->resumed());
  auto& regs = vmRegs();
  regs.stack.top() = (TypedValue*)ar - ar->numArgs();
  assert(vmStack().isValidAddress((uintptr_t)vmsp()));
  regs.pc = prevF->unit()->at(prevF->base() + ar->m_soff);
  regs.fp = prevAr;
}

///////////////////////////////////////////////////////////////////////////////

__thread bool AssertVMUnused::is_protected = false;

#ifndef NDEBUG

namespace {

__thread const AssertVMUnused* tl_top_prot = nullptr;

void protect() {
  rds::tl_base = nullptr;
  tl_regState = VMRegState::DIRTY;
  AssertVMUnused::is_protected = true;

  rds::threadInit();

  auto const protlen =
    rds::persistentSection().begin() - (const char*)rds::tl_base;

  // The current thread may attempt to read the Gen numbers of the normal
  // portion of rds.  These will all be invalid.  No writes to non-persistent
  // rds should occur while this guard is active.
  auto const result = mprotect(rds::tl_base, protlen, PROT_READ);
  always_assert(result == 0);
}

void deprotect(void* base, VMRegState state, bool prot) {
  rds::threadExit();

  AssertVMUnused::is_protected = prot;
  tl_regState = state;
  rds::tl_base = base;
}

}

AssertVMUnused::AssertVMUnused()
  : m_oldBase(rds::tl_base)
  , m_oldState(tl_regState)
  , m_oldProt(is_protected)
{
  if (!rds::tl_base) return;

  if (tl_top_prot == nullptr) tl_top_prot = this;
  protect();
}

AssertVMUnused::~AssertVMUnused() {
  if (!m_oldBase) return;

  deprotect(m_oldBase, m_oldState, m_oldProt);
  if (tl_top_prot == this) tl_top_prot = nullptr;
}

AssertVMUnusedDisabler::AssertVMUnusedDisabler() {
  if (auto const prot = tl_top_prot) {
    deprotect(prot->m_oldBase, prot->m_oldState, prot->m_oldProt);
  }
}

AssertVMUnusedDisabler::~AssertVMUnusedDisabler() {
  if (tl_top_prot) protect();
}

#endif

///////////////////////////////////////////////////////////////////////////////

}
