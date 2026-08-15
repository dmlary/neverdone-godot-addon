@tool
extends RefCounted
## Track missing GLTF `asset_ref` UIDs.  When those missing UIDs are
## imported, reimport those assets that depend on the missing UID.

var _log := Logrr.new()
var _filesystem: EditorFileSystem

## Map of MISSING asset_ref UID strings to a set of .gltf paths that reference
## them and have not yet resolved.
var _missing_uids := { }

## True once _missing_uids has been initialized with a full filesystem scan.
var _initialized := false

## Guards against re-entering the dependent-reimport logic from the signals it
## itself triggers.
var _reimporting := false


func _init(filesystem: EditorFileSystem) -> void:
    _filesystem = filesystem


## Do the pre-scan to find all missing asset-refs in the filesystem
func prescan(paths: Array) -> void:
    if _initialized:
        return
    _initialized = true

    # turn the paths into an exclude list.  We exclude these from the scan, and
    # let post-import report missing UIDs directly.
    var exclude := { }
    for path in paths:
        exclude[path] = true

    # wlk the full filesystem, getting the missing refs from all GLTF files
    var fs := _filesystem.get_filesystem()
    if fs == null:
        return
    var queue = [fs]
    if !queue.is_empty():
        var dir = fs
        for i in dir.get_subdir_count():
            queue.push_back(dir.get_subdir(i))
        for i in dir.get_file_count():
            var path = dir.get_file_path(i)
            if path.get_extension() != "gltf":
                continue
            if path in exclude:
                continue
            _find_missing_gltf_refs(path)


## Called from post-import plugin when it fails to load an asset UID.  We note
## the missing UID to trigger a later reimport.
func report_missing_uid(uid: String, source_path: String) -> void:
    if not _missing_uids.has(uid):
        _missing_uids[uid] = { }
    _missing_uids[uid][source_path] = true


## Called after new GLTF files have been imported.   If a missing UID has been
## imported, this will kick off a reimport of the asset that depends on that
## UID.
func reimport_resolved() -> void:
    # guard to not recursively re-import
    if _reimporting:
        return

    var to_reimport := { }
    for uid in _missing_uids.keys():
        if not ResourceUID.has_id(ResourceUID.text_to_id(uid)):
            continue # Still missing; not available yet.
        # uid became available during this batch; reimport everything that
        # references it, then forget it (it can no longer become available).
        for path in _missing_uids[uid]:
            if ResourceLoader.exists(path):
                to_reimport[path] = true
        _missing_uids.erase(uid)

    if to_reimport.is_empty():
        return

    _log.info(
        self,
        'Reimporting dependents of newly available assets: ',
        to_reimport.keys(),
    )
    _reimporting = true
    _filesystem.reimport_files(to_reimport.keys())
    _reimporting = false


## Sweep through a GLTF file, looking for missing asset_ref UIDs
func _find_missing_gltf_refs(gltf_path: String) -> void:
    var data = JSON.parse_string(
        FileAccess.open(gltf_path, FileAccess.READ).get_as_text(),
    )
    if not data is Dictionary:
        return # failed to parse the GLTF file

    # Loop through all the nodes in the GLTF file
    for node in data.get('nodes', []):
        # Get the asset_ref from the extras
        var extras: Dictionary = node.get('extras', { })
        var ref = extras.get('asset_ref', '')
        if not ref:
            continue

        # If the asset_ref refers to an invalid UID, let's add it to our
        # missing list.
        var uid = BlenderWorkflowPlugin.asset_uri(ref)
        if ResourceUID.has_id(ResourceUID.text_to_id(uid)):
            continue
        report_missing_uid(uid, gltf_path)
