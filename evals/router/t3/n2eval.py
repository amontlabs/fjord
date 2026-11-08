"""N2 evaluation: every table of docs/design/t3-research/N2-new-work-fixes.md from the saved answers (no model calls).

  python3 n2eval.py bars       per-action bars on N1's Sonnet answers
  python3 n2eval.py single     single-pass variants (v2, v3, base3), pilot or dev
  python3 n2eval.py stage      the new-work stage (Sonnet, Haiku) in front of a router
  python3 n2eval.py jev        Jev's fused path: the fjord check, and a fused new-work send (leave-one-day-out fit)
  python3 n2eval.py final [test]   the finalists, end to end (Jev path first, else Sonnet)
Aggregates only."""
import collections
import json
import pathlib
import sys

import numpy as np
from scipy.optimize import minimize

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import board as B  # noqa: E402
from n2score import (HEAD, M, anth_cost, board, jev_cost, load, logit, metrics, p50, paired, pct, row, sonnet_rule,  # noqa: E402
                     staged, weighted_mean)


def on(dec, ids):
    return {i: dec[i] for i in ids if i in dec}


def sonnet_decs(res, **bars):
    return {i: sonnet_rule(r["answer"], board(i), **bars) for i, r in res.items()}


def show(name, dec, split, sec=None, cost=None):
    mt = metrics(dec, split)
    lat = p50([sec[i] for i in dec if i in sec]) if sec else None
    c = weighted_mean({i: cost[i] for i in dec if i in cost}, split) if cost else None
    print(row(name, mt, lat, c))
    return mt


# ---------------------------------------------------------------- Jev: fused path with a new-work send
SHIPPED = dict(fjord=B.FJORD_BAR)


def jev_thread_send(r, fjord=B.FJORD_BAR):
    """The shipped send rule from a saved jev2 row, with the fjord bar as a parameter (None: no check)."""
    rows = r["rows"]
    if not rows: return None
    place, p, _, running = rows[0]
    if place[0] != "thread" or running or p < B.SEND_BAR or r["running_mass"] >= B.RUNNING_GUARD: return None
    if fjord is not None and r["fjord"] is not None and r["fjord"] >= fjord: return None
    return tuple(place)


def new_feats(r):
    top_thread = max([p for pl, p, _, _ in r["rows"] if pl[0] == "thread"] or [0])
    nc = max(list((r.get("nc") or {}).values()) or [0]); an = max(list((r.get("ans") or {}).values()) or [0])
    return [logit(r["new_mass"]), logit(r["newq"] or 0.5), logit(r["newc"] or 0.5), logit(top_thread), nc, an]


FEATS = ["logit route mass on new", "logit newq", "logit newc", "logit fused top thread", "max next-check", "max answers-check"]


def fit_logistic(X, y, l2=0.5, sw=None):
    X = np.c_[np.ones(len(X)), X]
    sw = np.ones(len(y)) if sw is None else np.asarray(sw)
    def nll(w):
        z = X @ w
        return np.sum(sw * (np.logaddexp(0, z) - y * z)) + l2 * np.sum(w[1:] ** 2)
    def grad(w):
        p = 1 / (1 + np.exp(-(X @ w)))
        g = X.T @ (sw * (p - y)); g[1:] += 2 * l2 * w[1:]
        return g
    return minimize(nll, np.zeros(X.shape[1]), jac=grad, method="L-BFGS-B").x


def predict(w, X):
    return 1 / (1 + np.exp(-(np.c_[np.ones(len(X)), np.asarray(X)] @ w)))


def jev_new_probs(J, split, fit_split="dev", cols=None):
    """P(new work) per moment. On the fit split: leave-one-day-out (each day scored by a fit without it). Else: the fit on
    all of fit_split. Training moments: new, new_continues, brief and follow-ups (fork starts left out)."""
    cols = cols or list(range(len(FEATS)))
    def data(sp):
        ids = [i for i, r in J.items() if M[i]["split"] == sp and M[i]["klass"] in ("new", "new_continues", "brief", "follow")]
        X = np.array([[new_feats(J[i])[c] for c in cols] for i in ids]); y = np.array([1.0 if M[i]["gold"][0] == "new" else 0.0 for i in ids])
        return ids, X, y
    ids, X, y = data(fit_split)
    if split == fit_split:
        days = np.array([M[i]["day"] for i in ids]); P = np.zeros(len(ids))
        for d in sorted(set(days)):
            w = fit_logistic(X[days != d], y[days != d])
            P[days == d] = predict(w, X[days == d])
        out = dict(zip(ids, P))
        w_all = fit_logistic(X, y)
    else:
        w_all = fit_logistic(X, y)
        ids2, X2, _ = data(split)
        out = dict(zip(ids2, predict(w_all, X2)))
    # fork starts and anything else: scored by the full fit
    rest = [i for i, r in J.items() if M[i]["split"] == split and i not in out]
    if rest:
        out.update(zip(rest, predict(w_all, np.array([[new_feats(J[i])[c] for c in cols] for i in rest]))))
    return out, w_all


def jev_path(J, pnew=None, new_bar=None, fjord=B.FJORD_BAR):
    """{id: ('thread', k) | ('new', p) | None}: the path's send, else None (hand to Sonnet)."""
    out = {}
    for i, r in J.items():
        s = jev_thread_send(r, fjord)
        if s is None and pnew is not None and new_bar is not None and pnew.get(i, 0) >= new_bar and r["new_probs"]:
            s = ("new", max(r["new_probs"].items(), key=lambda kv: kv[1])[0])
        out[i] = s
    return out


def combine(jp, sdec):
    return {i: (jp[i] if jp.get(i) else sdec[i]) for i in sdec if i in jp}


def as_dec(jp):
    return {i: (s if s else ("ask", ())) for i, s in jp.items()}


# ---------------------------------------------------------------- sections
def sec_bars():
    S = load("res_sonnet")
    dev = {i: r for i, r in S.items() if M[i]["split"] == "dev"}
    print("### N1 Sonnet answers, dev, bars swept\n" + HEAD + "\n" + "|---" * 14 + "|")
    for nb in (0.8, 0.75, 0.7, 0.65, 0.6, 0.5):
        show(f"new bar {nb}", sonnet_decs(dev, new=nb), "dev")
    for pb in (0.8, 0.9):
        show(f"new bar 0.6, project_confidence ≥ {pb}", sonnet_decs(dev, new=0.6, project_bar=pb), "dev")


def sec_single(names=("v2", "v3", "base3")):
    S = load("res_sonnet")
    for nm in names:
        R = load(f"n2_{nm}_dev")
        if not R: continue
        ids = set(R)
        sec = {i: r["sec"] for i, r in R.items()}; cost = {i: anth_cost(r) for i, r in R.items()}
        print(f"\n### {nm} (n={len(R)}) vs N1 Sonnet on the same moments, dev\n" + HEAD + "\n" + "|---" * 14 + "|")
        base = on(sonnet_decs({i: S[i] for i in ids if i in S}), ids)
        show("N1 Sonnet", base, "dev")
        for nb in (0.8, 0.7, 0.6):
            show(f"{nm}, new bar {nb}", sonnet_decs(R, new=nb), "dev", sec, cost)
        a = collections.Counter((M[i]["klass"], r["answer"]["action"]) for i, r in R.items())
        print("actions:", {k: v for k, v in sorted(a.items())})
        top = collections.Counter((M[i]["klass"], r["guess"][0] if r["guess"] else None,
                                   tuple(r["guess"]) == tuple(M[i]["gold"])) for i, r in R.items() if M[i]["klass"] in ("new", "follow"))
        print("top-1 (class, kind, right):", dict(sorted(top.items(), key=str)))


def sec_stage(bases=("res_sonnet",)):
    for st_name in ("stage_s", "stage_h"):
        ST = load(f"n2_{st_name}_dev")
        if not ST: continue
        for bname in bases:
            Bres = load(bname) if bname.startswith("res_") else load(f"n2_{bname}_dev")
            ids = [i for i in ST if i in Bres]
            bdec = {i: sonnet_rule(Bres[i]["answer"], board(i)) for i in ids}
            sec = {i: max(ST[i]["sec"], Bres[i]["sec"]) for i in ids}
            cost = {i: anth_cost(ST[i]) + anth_cost(Bres[i]) for i in ids}
            print(f"\n### {st_name} in front of {bname} (n={len(ids)}), dev; p50 = the slower of the two in parallel\n" + HEAD + "\n" + "|---" * 14 + "|")
            show(bname, bdec, "dev")
            for bar in (0.9, 0.8, 0.7, 0.6):
                for veto in (None, 0.5):
                    show(f"{st_name} new ≥ {bar}" + (f", veto ≥ {veto}" if veto else ""),
                         {i: staged(ST[i], bdec[i], bar=bar, veto=veto) for i in ids}, "dev", sec, cost)
            kinds = collections.Counter((M[i]["klass"], ST[i]["answer"]["kind"]) for i in ids)
            print("stage kinds:", dict(sorted(kinds.items(), key=str)))
            pr = [ST[i]["project_ok"] == M[i]["project"] for i in ids if M[i]["klass"] == "new" and ST[i]["answer"]["kind"] == "new"]
            print(f"stage project right when it says new on new work: {sum(pr)}/{len(pr)}")


def sec_jev(split="dev"):
    J = load(f"n2_jev2_{split}")
    J0 = load("res_jev")
    print(f"jev2 rows {len(J)}; shipped send agrees with N1's res_jev on "
          f"{sum((tuple(J[i]['send']) if J[i]['send'] else None) == (tuple(J0[i]['send']) if J0[i]['send'] else None) for i in J if i in J0)}/{len(J)}")
    sec = {i: r["sec"] for i, r in J.items()}; cost = {i: jev_cost(r) for i, r in J.items()}
    print(f"\n### Jev path alone, {split}, every moment (no sampling)\n" + HEAD + "\n" + "|---" * 14 + "|")
    for fj in (B.FJORD_BAR, 0.5, 0.7, None):
        show(f"shipped, fjord check {fj if fj is not None else 'off'}", as_dec(jev_path(J, fjord=fj)), split, sec, cost)
    for cols, nm in ((None, "all 6"), ([0, 1, 2], "new-work answers only"), ([0], "route mass only"), ([2], "newc only")):
        P, w = jev_new_probs(J, split, cols=cols)
        print(f"-- fused P(new) from {nm}: weights {np.round(w, 2).tolist()}")
        for bar in (0.9, 0.8, 0.7):
            for fj in (B.FJORD_BAR, None):
                show(f"+ new at P ≥ {bar} ({nm}), fjord {fj if fj is not None else 'off'}", as_dec(jev_path(J, P, bar, fjord=fj)), split, sec, cost)
    # project pick of the route's new options on new work
    ok = [max(J[i]["new_probs"].items(), key=lambda kv: kv[1])[0] == M[i]["project"] for i in J if M[i]["klass"] == "new" and J[i]["new_probs"]]
    print(f"route's top new project right on new work: {sum(ok)}/{len(ok)}")


def sec_probe():
    """The fjord check on written Fjord-intent probes (data/n2_probe_jev.jsonl, from n2probe.py)."""
    P = load("n2_probe_jev")
    if not P: return
    c = collections.Counter()
    for r in P.values():
        for fj in (B.FJORD_BAR, 0.5, 0.7, None):
            s = jev_thread_send(r, fj)
            c[(fj, "sent to a thread" if s else "handed to Sonnet")] += 1
    print(f"probes {len(P)}:", dict(sorted(c.items(), key=str)))


# ---------------------------------------------------------------- a fused new-work P over Sonnet's answer and Jev's answers
def fuse_feats(a, j):
    act, c = a.get("action"), a.get("confidence") or 0
    ext = a.get("extends")
    return [logit(c) if act == "new_work" else 0, logit(c) if act == "follow_up" else 0, 1.0 if act == "ask" else 0,
            0 if ext is None else (1.0 if ext else -1.0), logit(j["newc"] or 0.5), logit(j["new_mass"])]


FUSE_FEATS = ["new_work·logit conf", "follow_up·logit conf", "ask", "extends ±1", "logit Jev newc", "logit Jev route mass on new"]


def fused_new(R, J, split, fitR=None, fitJ=None):
    """P(new) per moment of R (a Sonnet variant's answers) with jev2 answers J: leave-one-day-out on dev, else the dev fit.
    Follow-ups are weighted back to the natural ratio in the fit."""
    def data(RR, JJ, sp):
        ids = [i for i in RR if i in JJ and M[i]["split"] == sp and M[i]["klass"] in ("new", "new_continues", "brief", "follow")]
        nf = sum(M[i]["klass"] == "follow" for i in ids)
        from n2score import N_FOLLOW
        wf = N_FOLLOW[sp] / max(nf, 1)
        X = np.array([fuse_feats(RR[i]["answer"], JJ[i]) for i in ids]); y = np.array([float(M[i]["gold"][0] == "new") for i in ids])
        sw = np.array([wf if M[i]["klass"] == "follow" else 1.0 for i in ids])
        return ids, X, y, sw
    if split == "dev":
        ids, X, y, sw = data(R, J, "dev")
        days = np.array([M[i]["day"] for i in ids]); P = np.zeros(len(ids))
        for d in sorted(set(days)):
            w = fit_logistic(X[days != d], y[days != d], sw=sw[days != d]); P[days == d] = predict(w, X[days == d])
        return dict(zip(ids, P)), fit_logistic(X, y, sw=sw)
    ids0, X0, y0, sw0 = data(fitR, fitJ, "dev")
    w = fit_logistic(X0, y0, sw=sw0)
    ids, X, _, _ = data(R, J, split)
    return dict(zip(ids, predict(w, X))), w


def fused_decision(i, a, j, p, sdec, bar, veto):
    """new at P >= bar (Sonnet's project when it said new_work, else Jev's top new project); a thread send turned into an ask
    at P >= veto; else Sonnet's decision."""
    if p >= bar:
        b = board(i)
        proj = b.project_named(a.get("project") or "") if a.get("action") == "new_work" else None
        proj = proj or (max(j["new_probs"].items(), key=lambda kv: kv[1])[0] if j["new_probs"] else None)
        if proj: return ("new", proj)
    if veto is not None and sdec[0] == "thread" and p >= veto: return ("ask", (sdec,))
    return sdec


def sec_fuse(names=("v2", "v3", "res_sonnet")):
    J = load("n2_jev2_dev")
    for nm in names:
        R = load(nm) if nm.startswith("res_") else load(f"n2_{nm}_dev")
        R = {i: r for i, r in R.items() if M[i]["split"] == "dev"}
        if not R: continue
        P, w = fused_new(R, J, "dev")
        print(f"\n### fused new-work P over {nm} + Jev (LODO), n={len(P)}; weights {np.round(w, 2).tolist()}\n" + HEAD + "\n" + "|---" * 14 + "|")
        for nb in (0.8, 0.7):
            show(f"{nm} alone, new bar {nb}", on(sonnet_decs(R, new=nb), P), "dev")
        for bar in (0.8, 0.7, 0.6, 0.5, 0.4):
            for veto in (None, 0.5, 0.3):
                sd = {i: sonnet_rule(R[i]["answer"], board(i), new=1.01) for i in P}
                show(f"fused P ≥ {bar}" + (f", veto ≥ {veto}" if veto else ""),
                     {i: fused_decision(i, R[i]["answer"], J[i], P[i], sd[i], bar, veto) for i in P}, "dev")


# ---------------------------------------------------------------- the finalists, end to end
def jev_sends(J, fjord=B.FJORD_BAR, guard=None):
    """Jev's fused path: the shipped thread send (fjord bar as given), held back when Jev's newc >= guard."""
    out = {}
    for i, r in J.items():
        s = jev_thread_send(r, fjord)
        if s and guard is not None and (r.get("newc") or 0) >= guard: s = None
        out[i] = s
    return out


def with_pnew(a, b, d, bar):
    """A new thread when Sonnet's p_new (v4's schema) reaches `bar`, in its project, unless it already decided new."""
    if bar is None or d[0] == "new" or (a.get("p_new") or 0) < bar: return d
    p = b.project_named(a.get("project") or "")
    return ("new", p) if p else d


def app(split, jv, sonnet, stage=None, fjord=B.FJORD_BAR, guard=None, new_bar=0.80, stage_bar=0.90, pnew_bar=None):
    """Jev's path first; when it doesn't send, the Sonnet router (and, in parallel, the new-work stage)."""
    J = load(jv); S = load(sonnet) if sonnet.startswith("res_") else load(f"n2_{sonnet}_{split}")
    ST = load(f"n2_{stage}_{split}") if stage else {}
    ids = [i for i in S if M[i]["split"] == split and i in J and (not stage or i in ST)]
    js = jev_sends({i: J[i] for i in ids}, fjord, guard)
    dec, sec, cost = {}, {}, {}
    for i in ids:
        sd = with_pnew(S[i]["answer"], board(i), sonnet_rule(S[i]["answer"], board(i), new=new_bar), pnew_bar)
        if stage: sd = staged(ST[i], sd, bar=stage_bar)
        dec[i] = js[i] or sd
        jsec, jc = J[i].get("sec") or 0, jev_cost(J[i])
        if js[i]: sec[i], cost[i] = jsec, jc
        else:
            sec[i] = jsec + max(S[i]["sec"], ST[i]["sec"] if stage else 0)
            cost[i] = jc + anth_cost(S[i]) + (anth_cost(ST[i]) if stage else 0)
    return dec, sec, cost


def finalists(split):
    """The three finalists picked on dev (N2's design section), plus the N1 app as the baseline."""
    jv2 = f"n2_jev2_{split}"
    return {
        "N1 app (shipped Jev path, then the shipped Sonnet)": app(split, "res_jev", "res_sonnet"),
        "T1: N1 app, new_work bar 0.70": app(split, "res_jev", "res_sonnet", new_bar=0.70),
        "T2: shipped Jev path, then v4 (new_work 0.80 or p_new 0.85)": app(split, "res_jev", "v4", new_bar=0.80, pnew_bar=0.85),
        "T3: Jev path with newc guard 0.3, then v4 (new_work 0.80 or p_new 0.85)": app(split, jv2, "v4", guard=0.3, new_bar=0.80, pnew_bar=0.85),
    }


def sec_final(split="dev"):
    F = finalists(split)
    print(f"### finalists, {split}\n" + HEAD + "\n" + "|---" * 14 + "|")
    for nm, (dec, sec, cost) in F.items():
        if dec: show(nm, dec, split, sec, cost)
    base = F["N1 app (shipped Jev path, then the shipped Sonnet)"][0]
    for nm, (dec, _, _) in F.items():
        if not dec or dec is base: continue
        print(nm)
        for k in ("new_right", "new_pushed", "follow_right", "follow_wrong", "follow_to_new", "pooled_sent", "pooled_wrong"):
            v, c = paired(dec, base, split, k)
            print(f"  {k}: {100 * v:+.1f} pts ({100 * c[0]:+.1f} to {100 * c[1]:+.1f})")
    for nm, (dec, sec, cost) in F.items():
        if dec:
            xs = sorted(sec.values())
            print(f"{nm}: p50 {p50(xs):.2f} s, p95 {xs[int(.95 * len(xs))]:.2f} s, n={len(dec)}")


if __name__ == "__main__":
    which = sys.argv[1]
    {"bars": sec_bars, "single": lambda: sec_single(), "stage": lambda: sec_stage(("res_sonnet", "v3")),
     "jev": lambda: sec_jev(sys.argv[2] if len(sys.argv) > 2 else "dev"), "probe": sec_probe, "fuse": lambda: sec_fuse(), "final": lambda: sec_final(sys.argv[2] if len(sys.argv) > 2 else "dev")}[which]()
