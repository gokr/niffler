import os
import hashlib
from datasets import load_dataset

# Target size (in bytes)
TARGET_SIZE = 1_000_000_000  
OUTPUT_FILE = "training_corpus.txt"

# Filtering thresholds
MIN_CHARS = 50     # skip snippets shorter than this
MAX_CHARS = 50000  # skip overly large blobs (helps balance)

def normalize(text: str) -> str:
    return text.strip().lower()

def hash_text(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()

def write_streaming_dataset(dataset, field, file_handle, max_chars, seen_hashes):
    written = 0
    kept = 0
    for example in dataset:
        # Some datasets have nested fields, adjust accordingly
        text = example.get(field, None)
        if text is None:
            continue

        text = text.strip().replace("\r\n", "\n")
        if not text:
            continue

        # Length filtering
        if len(text) < MIN_CHARS or len(text) > MAX_CHARS:
            continue

        # Deduplication
        h = hash_text(normalize(text))
        if h in seen_hashes:
            continue
        seen_hashes.add(h)

        file_handle.write(text + "\n")
        written += len(text.encode("utf-8"))
        kept += 1

        if written >= max_chars:
            break
    return written, kept


def main():
    if os.path.exists(OUTPUT_FILE):
        os.remove(OUTPUT_FILE)
    seen_hashes = set()
    total_written = 0
    total_kept = 0

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        print(">>> Sampling from The Stack (Python)...")
        stack_py = load_dataset("bigcode/the-stack", data_dir="data/python", split="train", streaming=True)
        w, k = write_streaming_dataset(stack_py, "content", f, int(TARGET_SIZE * 0.3), seen_hashes)
        total_written += w; total_kept += k

        print(">>> Sampling from The Stack (JavaScript)...")
        stack_js = load_dataset("bigcode/the-stack", data_dir="data/javascript", split="train", streaming=True)
        w, k = write_streaming_dataset(stack_js, "content", f, int(TARGET_SIZE * 0.3), seen_hashes)
        total_written += w; total_kept += k

        #print(">>> Sampling from StackExchange Q&A (H4)...")
        #se_h4 = load_dataset("HuggingFaceH4/stack-exchange-preferences", split="train", streaming=True)
        #w, k = write_streaming_dataset(se_h4, "text", f, int(TARGET_SIZE * 0.3), seen_hashes)
        #total_written += w; total_kept += k

        print(">>> Sampling from Wikipedia subset of The Pile...")
        wiki = load_dataset("wikimedia/wikipedia", "20231101.en", split="train", streaming=True)
        w, k = write_streaming_dataset(wiki, "text", f, int(TARGET_SIZE * 0.4), seen_hashes)
        total_written += w; total_kept += k


    print(f"\n✅ Finished! Wrote ~{total_written/1e6:.1f} MB of deduplicated text to {OUTPUT_FILE}")
    print(f"   Unique snippets kept: {total_kept}")

if __name__ == "__main__":
    main()
