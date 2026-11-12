"""Model check of the polling ring under C11 release/acquire memory.

standard-library.md "The ring algorithm" gives the algorithm this checks, and
its Validation list records what a run found. Run it with Python 3:

    python tests/model/ring_model.py           # the algorithm, then the mutants
    python tests/model/ring_model.py --quick   # capacities 1 and 2 only

Every shared access of the ring is a release store or an acquire load, and each
atomic location has a single writer (`tail` the sender, `head` the receiver,
each flag its endpoint's drop). For such a program C11's executions are exactly
those of the view-based operational model of release/acquire: a load may read
any store of its location no older than the thread's view of it, and an acquire
load of a release store joins the storing thread's view at the store. Release
sequences, RMWs, SC accesses, and fences do not arise, and po U rf is acyclic,
so no load-buffering outcome is missed. Each atomic access, slot access, and
endpoint-drop write is one step; the search explores every interleaving and
every permitted stale read, deduplicating states.

Happens-before is tracked with vector clocks, so a slot access, a final drain,
or a user's read after observing closure that is not ordered after the
conflicting access is reported as a data race.

Checked: FIFO order; no overwrite of a queued slot and no take of an empty one;
every item drains before `.closed`; exactly-once ownership of every item,
including the ring's drop after both endpoints join; once a send reports
`.closed` every later one does; and that an endpoint's drop happens before its
peer observes the side closed, by a plain write before each drop that the peer
reads after seeing `.closed`.

The mutants weaken one ordering each, or remove a line, and must fail. A
relaxed access is modelled with coherence but without synchronization; the
model then under-approximates C11 (no load buffering), which can only hide a
failure, never invent one.
"""

import sys

TAIL, HEAD, SG, RG = range(4)
LOCS = ("tail", "head", "sender_gone", "receiver_gone")
S, R, M = range(3)

BASE = {
    # try_send
    "send.1 receiver_gone": "acq",
    "send.5 head": "acq",
    "send.7 receiver_gone": "acq",
    "send.12 tail": "rel",
    "sender drop": "rel",
    # try_receive
    "receive.3 tail": "acq",
    "receive.5 sender_gone": "acq",
    "receive.6 tail": "acq",
    "receive.12 head": "rel",
    "receiver drop": "rel",
}


class Violation(Exception):
    pass


def zero_view():
    return ((0, 0, 0), (0, 0, 0, 0))


def join(a, b):
    return (
        tuple(max(x, y) for x, y in zip(a[0], b[0])),
        tuple(max(x, y) for x, y in zip(a[1], b[1])),
    )


def load(view, mem, loc, order):
    """Every (value, view) a load may produce."""
    out = []
    msgs = mem[loc]
    for i in range(view[1][loc], len(msgs)):
        value, mview = msgs[i]
        if order == "acq":
            nv = join(view, mview)
        else:
            idx = list(view[1])
            idx[loc] = max(idx[loc], i)
            nv = (view[0], tuple(idx))
        out.append((value, nv))
    return out


def store(view, mem, loc, value, order, tid):
    vc = list(view[0])
    vc[tid] += 1
    idx = list(view[1])
    idx[loc] = len(mem[loc])
    nv = (tuple(vc), tuple(idx))
    if order == "rel":
        mview = nv
    else:
        only = [0, 0, 0, 0]
        only[loc] = idx[loc]
        mview = ((0, 0, 0), tuple(only))
    mem = list(mem)
    mem[loc] = mem[loc] + ((value, mview),)
    return nv, tuple(mem)


def plain(view, epoch, tid, what):
    """A plain access ordered after `epoch` = (thread, clock); its own epoch."""
    if epoch is not None:
        t, c = epoch
        if t != tid and view[0][t] < c:
            raise Violation(f"data race on {what}")
    vc = list(view[0])
    vc[tid] += 1
    return (tuple(vc), view[1]), (tid, vc[tid])


def check(capacity, items, cfg):
    size = capacity + 1

    def nxt(p):
        return 0 if p + 1 == size else p + 1

    # Sender: (pc, tail, head_seen, item, holding, closed_seen, returned, view)
    # Receiver: (pc, head, tail_seen, received, view)
    # Shared: mem, slots ((content, epoch) per slot), user writes (S, R).
    s0 = ("B", 0, 0, 1, False, False, (), zero_view())
    r0 = ("B", 0, 0, 0, zero_view())
    mem0 = tuple(((v, zero_view()),) for v in (0, 0, False, False))
    slots0 = tuple((0, None) for _ in range(size))
    start = (s0, r0, mem0, slots0, (None, None))

    seen = {start}
    stack = [start]
    finals = 0

    def sender_steps(st):
        s, r, mem, slots, user = st
        pc, tail, hs, item, holding, closed_seen, returned, view = s
        out = []

        def put(**k):
            ns = dict(pc=pc, tail=tail, hs=hs, item=item, holding=holding,
                      closed_seen=closed_seen, returned=returned, view=view)
            ns.update(k)
            ss = (ns["pc"], ns["tail"], ns["hs"], ns["item"], ns["holding"],
                  ns["closed_seen"], ns["returned"], ns["view"])
            out.append((ss, r, k.get("mem", mem), k.get("slots", slots),
                        k.get("user", user)))

        def result(kind, view):
            if closed_seen and kind != "closed":
                raise Violation(f"send reported {kind} after .closed")
            if kind == "closed":
                # The receiver's drop happens before this observation.
                if user[1] is None:
                    raise Violation(".closed before the receiver's drop")
                if cfg.get("drop contract", True):
                    view, _ = plain(view, user[1], S,
                                    "the receiver's last write")
                put(pc="B", item=item + 1, holding=False, closed_seen=True,
                    returned=returned + (item,), view=view)
            elif kind == "full":
                put(pc="B", holding=True, view=view)

        if pc == "B":
            if item <= items:
                put(pc="1")
            put(pc="D0")
        elif pc == "1":
            for v, nv in load(view, mem, RG, cfg["send.1 receiver_gone"]):
                if v and cfg.get("first closure check", True):
                    result("closed", nv)
                else:
                    put(pc="2", view=nv)
        elif pc == "2":
            n = nxt(tail)
            if n == hs and cfg.get("fullness check", True):
                put(pc="5")
            else:
                put(pc="11")
        elif pc == "5":
            for v, nv in load(view, mem, HEAD, cfg["send.5 head"]):
                if nxt(tail) == v:
                    put(pc="7", hs=v, view=nv)
                else:
                    put(pc="11", hs=v, view=nv)
        elif pc == "7":
            for v, nv in load(view, mem, RG, cfg["send.7 receiver_gone"]):
                result("closed" if v else "full", nv)
        elif pc == "11":
            content, epoch = slots[tail]
            if content:
                raise Violation(f"send overwrote queued item {content}")
            nv, ep = plain(view, epoch, S, f"slot {tail}")
            sl = list(slots)
            sl[tail] = (item, ep)
            put(pc="12", view=nv, slots=tuple(sl))
        elif pc == "12":
            n = nxt(tail)
            nv, nm = store(view, mem, TAIL, n, cfg["send.12 tail"], S)
            put(pc="B", tail=n, item=item + 1, holding=False, view=nv, mem=nm)
        elif pc == "D0":
            # A write of the sender's, before its drop, that the receiver reads
            # once it sees `.closed`.
            vc = list(view[0])
            vc[S] += 1
            nv = (tuple(vc), view[1])
            back = returned + ((item,) if holding else ())
            put(pc="D1", view=nv, returned=back, holding=False,
                item=item + 1 if holding else item,
                user=((S, vc[S]), user[1]))
        elif pc == "D1":
            nv, nm = store(view, mem, SG, True, cfg["sender drop"], S)
            put(pc="done", view=nv, mem=nm)
        return out

    def receiver_steps(st):
        s, r, mem, slots, user = st
        pc, head, ts, got, view = r
        out = []

        def put(pc=pc, head=head, ts=ts, got=got, view=view, mem=mem,
                slots=slots, user=user):
            out.append((s, (pc, head, ts, got, view), mem, slots, user))

        if pc == "B":
            put(pc="1")
            put(pc="D0")
        elif pc == "1":
            put(pc="3" if head == ts else "10")
        elif pc == "3":
            for v, nv in load(view, mem, TAIL, cfg["receive.3 tail"]):
                put(pc="5" if head == v else "10", ts=v, view=nv)
        elif pc == "5":
            for v, nv in load(view, mem, SG, cfg["receive.5 sender_gone"]):
                put(pc="6" if v else "B", view=nv)
        elif pc == "6":
            if not cfg.get("final tail reload", True):
                vals = [(ts, view)]
            else:
                vals = load(view, mem, TAIL, cfg["receive.6 tail"])
            for v, nv in vals:
                if head != v:
                    put(pc="10", ts=v, view=nv)
                    continue
                # `.closed`: the sender has dropped, so its count is final.
                committed = s[3] - 1 - len(s[6])
                if s[0] != "done":
                    raise Violation(".closed before the sender's drop")
                if got != committed:
                    raise Violation(
                        f".closed with {committed - got} committed item(s) "
                        "undelivered")
                if user[0] is None:
                    raise Violation(".closed before the sender's write")
                if cfg.get("drop contract", True):
                    nv, _ = plain(nv, user[0], R, "the sender's last write")
                put(pc="D0", ts=v, view=nv)
        elif pc == "10":
            content, epoch = slots[head]
            if not content:
                raise Violation(f"receive took empty slot {head}")
            if content != got + 1:
                raise Violation(f"received {content}, expected {got + 1}")
            nv, ep = plain(view, epoch, R, f"slot {head}")
            sl = list(slots)
            sl[head] = (0, ep)
            put(pc="12", got=got + 1, view=nv, slots=tuple(sl))
        elif pc == "12":
            n = nxt(head)
            nv, nm = store(view, mem, HEAD, n, cfg["receive.12 head"], R)
            put(pc="B", head=n, view=nv, mem=nm)
        elif pc == "D0":
            vc = list(view[0])
            vc[R] += 1
            put(pc="D1", view=(tuple(vc), view[1]), user=(user[0], (R, vc[R])))
        elif pc == "D1":
            nv, nm = store(view, mem, RG, True, cfg["receiver drop"], R)
            put(pc="done", view=nv, mem=nm)
        return out

    def ring_drop(st):
        """Both endpoints joined: drain from `head` to `tail` as plain reads."""
        s, r, mem, slots, user = st
        view = join(s[7], r[4])
        for loc in (TAIL, HEAD):
            if view[1][loc] != len(mem[loc]) - 1:
                raise Violation(f"ring drop reads a stale {LOCS[loc]}")
        head, tail = mem[HEAD][-1][0], mem[TAIL][-1][0]
        drained = []
        slots = list(slots)
        while head != tail:
            content, epoch = slots[head]
            if not content:
                raise Violation(f"ring drop found slot {head} empty")
            view, _ = plain(view, epoch, M, f"slot {head}")
            drained.append(content)
            slots[head] = (0, None)
            head = nxt(head)
        if any(c for c, _ in slots):
            raise Violation("an item outlives the ring")
        got = r[3]
        owned = list(range(1, got + 1)) + drained + list(s[6])
        attempted = s[3] - 1
        if sorted(owned) != list(range(1, attempted + 1)):
            raise Violation(f"ownership: items {sorted(owned)} of {attempted}")
        if drained != list(range(got + 1, got + 1 + len(drained))):
            raise Violation(f"ring drop order {drained}")

    while stack:
        st = stack.pop()
        try:
            succ = []
            if st[0][0] != "done":
                succ += sender_steps(st)
            if st[1][0] != "done":
                succ += receiver_steps(st)
            if not succ:
                ring_drop(st)
                finals += 1
        except Violation as e:
            return str(e), len(seen)
        for n in succ:
            if n not in seen:
                seen.add(n)
                stack.append(n)
    return None, len(seen), finals


# (name, change, expected): `expected` is the failure the mutant must show, or
# None for a weakening the algorithm tolerates.
#
# The ring's own safety needs `tail` and `head` published and acquired, and
# `sender_gone` too: without it a receiver can see the sender gone yet miss its
# last item. `receiver_gone`'s orderings protect only the promise that a drop
# happens before its peer sees the side closed, so with that check off
# ("drop contract") they may be relaxed. Line 6 of `try_receive` may be relaxed
# as well: line 5's acquire of `sender_gone` already synchronizes with the
# sender's drop, which is sequenced after its last `tail` store.
RACE = "data race on slot"
UNDELIVERED = "undelivered"
CONTRACT = "last write"
NO_CONTRACT = {"drop contract": False}
MUTANTS = [
    ("send.12 tail relaxed", {"send.12 tail": "rlx"}, RACE),
    ("receive.3 tail relaxed", {"receive.3 tail": "rlx"}, RACE),
    ("receive.12 head relaxed", {"receive.12 head": "rlx"}, RACE),
    ("send.5 head relaxed", {"send.5 head": "rlx"}, RACE),
    ("sender drop relaxed", {"sender drop": "rlx", **NO_CONTRACT},
     UNDELIVERED),
    ("receive.5 sender_gone relaxed",
     {"receive.5 sender_gone": "rlx", **NO_CONTRACT}, UNDELIVERED),
    ("receiver drop relaxed", {"receiver drop": "rlx"}, CONTRACT),
    ("send.1 receiver_gone relaxed", {"send.1 receiver_gone": "rlx"},
     CONTRACT),
    ("send.7 receiver_gone relaxed", {"send.7 receiver_gone": "rlx"},
     CONTRACT),
    ("receiver drop relaxed, no drop contract",
     {"receiver drop": "rlx", **NO_CONTRACT}, None),
    ("both receiver_gone loads relaxed, no drop contract",
     {"send.1 receiver_gone": "rlx", "send.7 receiver_gone": "rlx",
      **NO_CONTRACT}, None),
    ("receive.6 tail relaxed", {"receive.6 tail": "rlx"}, None),
    ("no final tail reload", {"final tail reload": False}, UNDELIVERED),
    ("no fullness check", {"fullness check": False}, "outlives the ring"),
]


def main():
    quick = "--quick" in sys.argv
    capacities = (1, 2) if quick else (1, 2, 3)
    ok = True
    for cap in capacities:
        items = 2 * (cap + 1) + 1  # past two laps of the slots
        res = check(cap, items, BASE)
        if res[0] is None:
            print(f"capacity {cap}, {items} items: no violation "
                  f"({res[1]} states, {res[2]} final)")
        else:
            ok = False
            print(f"capacity {cap}, {items} items: VIOLATION {res[0]}")
    for name, change, expected in MUTANTS:
        cfg = dict(BASE, **change)
        found = None
        for cap in capacities:
            res = check(cap, 2 * (cap + 1) + 1, cfg)
            if res[0] is not None:
                found = (cap, res[0])
                break
        if found and expected and expected in found[1]:
            print(f"mutant {name}: fails at capacity {found[0]}: {found[1]}")
        elif not found and expected is None:
            print(f"mutant {name}: holds, as expected")
        else:
            ok = False
            got = f"capacity {found[0]}: {found[1]}" if found else "holds"
            print(f"mutant {name}: UNEXPECTED ({got}; expected "
                  f"{expected or 'to hold'})")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
