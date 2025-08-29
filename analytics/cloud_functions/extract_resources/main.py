from google.cloud import storage
import json
import os
import tempfile


def _extract_bundle_text_to_ndjson(text: str, out_f):
    """Write resources found in text to out_f as NDJSON (one JSON per line)."""
    # Try full-document parse (single Bundle)
    try:
        obj = json.loads(text)
        if isinstance(obj, dict) and 'entry' in obj:
            for e in obj.get('entry', []):
                if isinstance(e, dict):
                    r = e.get('resource')
                    if r is not None:
                        out_f.write(json.dumps(r, ensure_ascii=False) + "\n")
            return
    except Exception:
        pass

    # Fallback: NDJSON or multiple JSON objects per line
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            if 'entry' in obj:
                for e in obj.get('entry', []):
                    if isinstance(e, dict):
                        r = e.get('resource')
                        if r is not None:
                            out_f.write(json.dumps(r, ensure_ascii=False) + "\n")
            elif 'resourceType' in obj or 'id' in obj:
                out_f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def extract_resources_gcs(event, context):
    """Cloud Function entry point.

    Trigger: google.storage.object.finalize (object creation) on the bucket.
    Expects Synthea/Bundle files under `synthea_batches/` with `.ndjson` suffix.
    Writes a per-resource NDJSON file to `processed_resources/<basename>-resources.ndjson`.
    """
    bucket_name = event.get('bucket')
    name = event.get('name')
    if not bucket_name or not name:
        print('Missing event.bucket or event.name')
        return

    # Quick filter to only process expected batch files
    if not name.startswith('synthea_batches/') or not name.endswith('.ndjson'):
        print(f"Skipping object not in synthea_batches/ or not .ndjson: {name}")
        return

    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(name)

    print(f'Downloading gs://{bucket_name}/{name} to temp file')
    # Stream download to a temp file to avoid loading large files into memory
    with tempfile.NamedTemporaryFile(mode='w+b', delete=False) as dl_tmp:
        dl_path = dl_tmp.name
    blob.download_to_filename(dl_path)

    base = os.path.basename(name).replace('.ndjson', '')
    out_prefix = os.environ.get('PROCESSED_PREFIX', 'processed_resources')
    dest_name = f'{out_prefix}/{base}-resources.ndjson'

    # Process input file line-by-line and write NDJSON resources to another temp file
    written_count = 0
    with tempfile.NamedTemporaryFile(mode='w', delete=False) as out_tmp:
        out_path = out_tmp.name
        with open(dl_path, 'r', encoding='utf-8') as inf:
            for line in inf:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    # ignore malformed lines
                    continue
                # If the line is a bundle with entries
                if isinstance(obj, dict) and 'entry' in obj:
                    for e in obj.get('entry', []):
                        if isinstance(e, dict):
                            r = e.get('resource')
                            if r is not None:
                                out_tmp.write(json.dumps(r, ensure_ascii=False) + "\n")
                                written_count += 1
                    continue
                # If the line is a resource object
                if isinstance(obj, dict) and ('resourceType' in obj or 'id' in obj):
                    out_tmp.write(json.dumps(obj, ensure_ascii=False) + "\n")
                    written_count += 1

    # If nothing was written and the input file is small, try parsing whole file as JSON (pretty-printed bundle)
    try:
        if written_count == 0:
            size_bytes = os.path.getsize(dl_path)
            # safe threshold to avoid reading very large files into memory
            if size_bytes <= 50 * 1024 * 1024:  # 50 MB
                with open(dl_path, 'r', encoding='utf-8') as inf:
                    try:
                        obj = json.load(inf)
                        if isinstance(obj, dict) and 'entry' in obj:
                            with open(out_path, 'a', encoding='utf-8') as out_tmp_append:
                                for e in obj.get('entry', []):
                                    if isinstance(e, dict):
                                        r = e.get('resource')
                                        if r is not None:
                                            out_tmp_append.write(json.dumps(r, ensure_ascii=False) + "\n")
                                            written_count += 1
                    except Exception:
                        # If parsing whole file fails, just proceed with empty output
                        pass
    except Exception:
        pass

    # Upload result
    dest_blob = bucket.blob(dest_name)
    dest_blob.upload_from_filename(out_path, content_type='application/x-ndjson')

    # Clean up
    try:
        os.remove(dl_path)
    except Exception:
        pass
    try:
        os.remove(out_path)
    except Exception:
        pass

    print(f'Wrote resources to gs://{bucket_name}/{dest_name}')
