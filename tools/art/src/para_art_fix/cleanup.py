"""Step 5 (report §6.1 step 5, §5.3): orphan-pixel cleanup, using the exact
same definition `tools/para/art/lint.nim`'s `analyzeAsset` checks against -
any visible pixel with no visible 8-neighbour - so a cleaned sprite always
measures 0 orphans under `para art lint`. Single pass: an orphan by this
definition has no visible neighbours at all, so removing it can never turn
some other pixel into a new orphan.
"""

from __future__ import annotations

import numpy as np


def remove_orphans(rgba: np.ndarray) -> tuple[np.ndarray, dict]:
    alpha = rgba[..., 3] > 0
    h, w = alpha.shape
    padded = np.pad(alpha, 1, constant_values=False)
    neighbours = np.zeros((h, w), dtype=np.int32)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            neighbours += padded[1 + dy:1 + dy + h, 1 + dx:1 + dx + w].astype(np.int32)
    orphans = alpha & (neighbours == 0)
    out = rgba.copy()
    out[orphans] = 0
    return out, {"removed": int(orphans.sum())}
