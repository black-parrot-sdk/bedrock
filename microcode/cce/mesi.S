# This microcode uses MESI protocol with speculative memory access

#include "microcode.h"

# send sync messages
# r0 counts up from 0 number of sync messages sent
# r1 holds constant numLCE
# r3 stores the constant SYNC_ACK to check response ack type against
# The CCE waits for sync ack after each sync command. This avoids additional buffering being
# required in the CCE, at a small "performance" cost during startup
sync_init: movi 0 r0
movpg numLCE r1
movi SYNC_ACK r3
sync_top: bge r0 r1 finish_init
pushq lceCmd SYNC addr=0 lce=r0 way=0
popq lceResp r4
inc r0
bi sync_top

# set default value for mshr.next_coh_state
finish_init: movip COH_E cohSt

# Wait for LCE Requests
# Try to fast-path the request
ready: clm
poph lceReq r0
rdp addr=req
# pending or uncached should be handled without issuing a speculative access
bfnz handle_pf_ucf pf ucf
# send speculative memory access, also sets speculative flag
# assumed state for block is E
pushq memCmd MEM_CMD_RD addr=req lce=req way=lru spec=1 wp=1
# dequeue the request
popq lceReq wp
# read the directory and process
rdw addr=req lce=req lru_way=lru
gad
# handle slowly if write, transfer, replacement, upgrade, or block cached in S
bfnz handle_req rqf cmf cef csf rf uf nerf

# complete fast path access
# uses the speculative memory access
fast_path_complete: wde addr=req lce=req way=lru state=nextCohSt
# clear spec bit
specq unset req
# request handling complete
bi ready

# Handle request that wasn't easily fast-pathed

# Replacement Check Routine
handle_req: bfz next_coh_state rf

# Replacement Routine
replace: movis COH_I nextCohSt
pushq lceCmd ST_WB addr=lru lce=req way=lru
# wait for writeback response
replacement_poph: poph lceResp r0
beqi r0 COH_ACK replacement_poph
bf complete_replacement nwbf
pushq memCmd MEM_CMD_WR addr=lru lce=req way=lru wp=1 src=lcerespdata
bi next_coh_state
complete_replacement: popq lceResp

# Next Coherence State Routine
# write request means set to M, else check non-exclusive request
next_coh_state: bf next_coh_set_m rqf
# non-exclusive request (read-only) or blocked cached somewhere, set to S
bfnz next_coh_set_s nerf csf cef cmf
# invalidations not required, thus block not cache, set to E
next_coh_set_e: movis COH_E nextCohSt
bi inv_check
next_coh_set_s: movis COH_S nextCohSt
bi inv_check
next_coh_set_m: movis COH_M nextCohSt
# fall through to inv_check

# Invalidation Check
inv_check: bfnot upgrade_check rqf csf pt

# Invalidation Routine
invalidate: inv

# Upgrade Check Routine
upgrade_check: bfz set_entry uf pt

# Upgrade Routine
upgrade: wds addr=req lce=req way=req state=nextCohSt
pushq lceCmd STW addr=req lce=req way=req
specq squash req
bi ready

set_entry: wde addr=req lce=req way=lru state=nextCohSt

# Transfer Check
transfer_check: bfz read_l2 cmf cef pt
# transfer, squash speculative access
specq squash req

# Transfer routine - other cache has block in E/M
# write requests invalidate owner, read requests downgrade owner to S and writeback
transfer: bf transfer_write rqf

# transfer from owner in E/M, downgrade owner to S, send block to req in S
# writeback block from owner
movis COH_S ownerCohSt
pushq lceCmd ST_TR_WB addr=req lce=owner way=owner
wds addr=req lce=owner way=owner state=ownerCohSt
# wait for transfer WB response
transfer_poph: poph lceResp r0
beqi r0 COH_ACK transfer_poph
bf complete_transfer nwbf
pushq memCmd MEM_CMD_WR addr=lceresp lce=owner way=owner wp=1 src=lcerespdata
bi ready
complete_transfer: popq lceResp
bi ready

transfer_write: movis COH_I ownerCohSt
pushq lceCmd ST_TR addr=req lce=owner way=owner
wds addr=req lce=owner way=owner state=ownerCohSt
bi ready

# Read Line from L2 Routine
# memory access was already issued speculatively (E), so resolve the speculation
read_l2: bf resolve_fwd_mod_m rqf
bfnz resolve_fwd_mod_s csf nerf
resolve_e: specq unset req
bi ready
resolve_fwd_mod_m: specq fwd_mod req COH_M
bi ready
resolve_fwd_mod_s: specq fwd_mod req COH_S
bi ready

# handle pending flag set or uncached access
# pending jumps back to ready, waits for memory response to return and clear flag
handle_pf_ucf: bf ready pf
# Uncached Request Routine
uncached_req: bf uc_coherent rcf
bf uncached_store rqf
pushq memCmd MEM_CMD_RD addr=req lce=req
popq lceReq
bi ready
uncached_store: pushq memCmd MEM_CMD_WR addr=req lce=req src=lcereqdata
bi ready

# Uncached request to coherent/cacheable memory
uc_coherent: rdp addr=req
bf uc_coherent pf
rdw addr=req lce=req lru_way=lru
gad
movis COH_I nextCohSt
movsg msgsize r7
movis SIZE_64 msgsize

bfz uc_inv_check rf

# Replacement Routine
pushq lceCmd ST_WB addr=req lce=req way=req
wds addr=req lce=req way=req state=imm COH_I
uc_replacement_poph: poph lceResp r0
beqi r0 COH_ACK uc_replacement_poph
bf uc_complete_replacement nwbf
pushq memCmd MEM_CMD_WR addr=lceresp lce=req way=req wp=1 src=lcerespdata
bi uc_inv_check
uc_complete_replacement: popq lceResp

# Invalidate any cache with block in S
uc_inv_check: bfz uc_owned_check csf pt
inv

# Invalidate and WB owner cache
uc_owned_check: bfz uc_mem cmf cef pt
pushq lceCmd ST_WB addr=req lce=owner way=owner
wds addr=req lce=owner way=owner state=imm COH_I
uc_inv_poph: poph lceResp r0
beqi r0 COH_ACK uc_inv_poph
bf uc_complete_inv nwbf
pushq memCmd MEM_CMD_WR addr=lceresp lce=req way=req wp=1 src=lcerespdata
bi uc_mem
uc_complete_inv: popq lceResp

uc_mem: movgs r7 msgsize
bf coherent_store rqf
pushq memCmd MEM_CMD_RD addr=req lce=req wp=1
popq lceReq
bi ready
coherent_store: pushq memCmd MEM_CMD_WR addr=req lce=req wp=1 src=lcereqdata
bi ready

