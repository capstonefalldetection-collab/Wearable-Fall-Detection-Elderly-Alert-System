"""
Split the balanced windows into train/ and test/ by SUBJECT, not by window.

Critical: a subject's data must appear entirely in train OR entirely in
test, never both -- otherwise the model can partially memorize a person's
movement signature and your test accuracy becomes meaningless.

Filenames look like:
  fall_SA01_F01_R01_00001.csv
  no_fall_SA01_D01_R01_00001.csv
"""

import re
import random
import shutil
from pathlib import Path
from collections import defaultdict

BALANCED_DIR = Path("SisFall_windows/balanced")
SPLIT_DIR = Path("SisFall_windows/split")

TEST_FRACTION = 0.2   # ~20% of subjects held out for test
RNG_SEED = 42

FNAME_RE = re.compile(r"^(fall|no_fall)_([A-Z]{2}\d+)_")


def main():
    random.seed(RNG_SEED)

    # Collect every subject that appears anywhere in the balanced set.
    all_subjects = set()
    for label in ["fall", "no_fall"]:
        for f in (BALANCED_DIR / label).glob("*.csv"):
            m = FNAME_RE.match(f.name)
            if m:
                all_subjects.add(m.group(2))

    subjects = sorted(all_subjects)
    random.shuffle(subjects)
    n_test = max(1, int(len(subjects) * TEST_FRACTION))
    test_subjects = set(subjects[:n_test])
    train_subjects = set(subjects[n_test:])

    print(f"Total subjects: {len(subjects)}")
    print(f"Train subjects ({len(train_subjects)}): {sorted(train_subjects)}")
    print(f"Test subjects  ({len(test_subjects)}): {sorted(test_subjects)}")

    for split_name, subject_set in [("train", train_subjects), ("test", test_subjects)]:
        for label in ["fall", "no_fall"]:
            out_dir = SPLIT_DIR / split_name / label
            out_dir.mkdir(parents=True, exist_ok=True)

    counts = defaultdict(int)
    for label in ["fall", "no_fall"]:
        for f in (BALANCED_DIR / label).glob("*.csv"):
            m = FNAME_RE.match(f.name)
            if not m:
                continue
            subject = m.group(2)
            split_name = "test" if subject in test_subjects else "train"
            shutil.copy(f, SPLIT_DIR / split_name / label / f.name)
            counts[(split_name, label)] += 1

    print("\nFinal counts:")
    for (split_name, label), n in sorted(counts.items()):
        print(f"  {split_name}/{label}: {n}")

    for split_name in ["train", "test"]:
        f = counts[(split_name, "fall")]
        nf = counts[(split_name, "no_fall")]
        print(f"  {split_name} ratio (no_fall/fall): {nf / max(f,1):.2f}")


if __name__ == "__main__":
    main()
