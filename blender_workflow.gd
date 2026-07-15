@tool
extends EditorPlugin

class_name BlenderWorkflowPlugin

## At various points in the workflow we may need to fetch additional data from
## the GLTF file.  Let's parse it once, and pass it around for use
class GltfWrapper:
    ## Path to the GLTF file
    var path: String
    ## Parsed GLTF JSON
    var data: Dictionary
    ## Cached scene extras
    var scene_extras: Dictionary
    ## Cache the node heirarchy so we can go from Godot node path to GLTF file
    ## node index
    var _node_path_cache: Dictionary


    func _init(gltf_path):
        path = gltf_path
        data = JSON.parse_string(
            FileAccess.open(path, FileAccess.READ).get_as_text(),
        )
        var scene = data['scenes'][data['scene']]
        scene_extras = scene.get('extras', { })


    ## Convert the full node hierarchy into a cache we can lookup node indexes
    ## by Godot NodePath strings.  This is needed to support looking up
    ## animation channels by Godot NodePath for per-channel interpolation
    ## override.
    func _build_node_path_cache():
        _node_path_cache = { }
        var bone_set = { }

        # Grab the list of node indexes that are for bones.  This matters
        # later because Godot does bone heirarchy flattening during 4.5+ import
        for skin in data.get('skins', []):
            for j in skin.get('joints', []):
                # Gotta convert it to an int here because they're floats by
                # default -__-
                bone_set[int(j)] = true

        # print("XXX ", bone_set)

        # Walk the GLTF node hierarchy building our node cache
        var root_nodes = data['scenes'][data['scene']].get('nodes', [])
        for idx in root_nodes:
            _walk_and_cache(idx, '', bone_set)

        # print("XXX ", _node_path_cache)


    ## Walks the GLTF node list and populates the node path cache.
    func _walk_and_cache(idx: int, parent_path: String, bone_set: Dictionary):
        var node = data.nodes[idx]
        var name = node.get('name', '')
        var key ## NodePath string for this node
        var prefix ## NodePath prefix for all children of this node

        # If this node is a bone, we need to handle it differently from a
        # normal node.  Bones get shoved under a Skeleton3D, and their
        # heirarchy flattened.  This is the Godot 4.5+ import mode.  Not
        # guaranteed to work with the older import modes.
        # Also not guaranteed to work with multiple armatures because I didn't
        # test it.
        if bone_set.has(idx):
            if parent_path:
                key = parent_path + '/Skeleton3D:' + name
            else:
                key = 'Skeleton3D:' + name

            # Godot flattens bone hierarchy, so keep our parent path as prefix
            prefix = parent_path
        else:
            # Normal node, let's just traverse, and new prefix is our key
            key = parent_path + '/' + name if parent_path else name
            prefix = key

        # Save the info to the cache
        _node_path_cache[key] = idx

        # Walk the children
        for child in node.get('children', []):
            _walk_and_cache(child, prefix, bone_set)


    ## Get the animation by name (handles name stripping)
    func get_animation(name) -> Dictionary:
        for animation in data['animations']:
            # support both the GLTF name, and the godot import stripped name
            var stripped_name = strip_animation_suffix(animation.name)
            if (stripped_name && stripped_name == name) || (animation.name == name):
                return animation
        return { }


    ## Get the extras set on an animation track by Godot name (stripped of
    ## suffix)
    func get_animation_extras(name) -> Dictionary:
        var animation = get_animation(name)
        if animation == null:
            return { }

        return animation.get('extras', { })


    ## Get the gltf channel for a given animation name and track NodePath
    func get_animation_channel(animation_name: String, track_path: NodePath) -> Dictionary:
        # Populate the cache if we haven't already
        if _node_path_cache.is_empty():
            _build_node_path_cache()

        # Lookup the node index for this path from the node cache
        var node_idx = _node_path_cache.get(str(track_path), -1)
        if node_idx < 0:
            return { }

        # Now with the GLTF node index from the NodePath, we find which channel
        # in the animation matches our node
        var animation = get_animation(animation_name)
        for channel in animation['channels']:
            if channel.target.node == node_idx:
                return channel

        return { }


    ## Strip the -loop/-cycle suffix from an animation name if present.
    ## If the suffix isn't present, will return null
    func strip_animation_suffix(name) -> Variant:
        for suffix in ['-loop', '-cycle', '_loop', '_cycle']:
            if name.ends_with(suffix):
                return name.substr(0, name.length() - suffix.length())
        return null


var log := Logrr.new()
var post_import_plugin = preload('post_import_plugin.gd').new()

var file_system_signals = {
    # "filesystem_changed": _on_filesystem_changed,
    "resources_reimporting": _on_resources_reimporting,
    "resources_reimported": _on_resources_reimported,
    # "resources_reload": _on_resources_reload,
    # "sources_changed": _on_sources_changed,
}


func _enable_plugin() -> void:
    # Add autoloads here.
    pass


func _disable_plugin() -> void:
    # Remove autoloads here.
    pass


func _enter_tree() -> void:
    log.set_level(self, Logrr.Level.TRACE)
    add_scene_post_import_plugin(post_import_plugin)

    var file_system := get_editor_interface().get_resource_filesystem()
    for s in self.file_system_signals:
        file_system.connect(s, self.file_system_signals[s])


func _exit_tree() -> void:
    # Clean-up of the plugin goes here.
    remove_scene_post_import_plugin(post_import_plugin)

    var file_system := get_editor_interface().get_resource_filesystem()
    for s in self.file_system_signals:
        file_system.connect(s, self.file_system_signals[s])


func _on_sources_changed(exist):
    # called every time we focus godot
    log.trace(self, 'exist ', exist)


func _on_filesystem_changed():
    log.trace(self, '')


## Run before resources are imported
func _on_resources_reimporting(paths):
    for path in paths:
        if not path.get_extension() == 'gltf':
            continue
        log.trace(self, path)
        setup_import_config(path)


## Run after resources are imported
func _on_resources_reimported(paths):
    for path in paths:
        if not path.get_extension() == 'gltf':
            continue
        log.trace(self, path)

        # For Scene + GLTF exports, we may need to create the .tscn file if it
        # doesn't already exist.
        var gltf = GltfWrapper.new(path)
        var extras = gltf.scene_extras
        var asset_type = extras.get(&'asset_type', &'')
        var workflow_props = extras.get(&'godot_workflow_props', &'')

        # if we imported a Scene asset, we need to make sure there is a scene
        # to point at the GLTF
        if asset_type == 'SCENE' || asset_type == 'INHERIT':
            var uid = asset_uri(extras.get(&'asset_id'))
			var tscn_path = _gltf_scene_path(path).replace("/export/", "/")
            var scene_base
            if asset_type == 'SCENE':
                scene_base = workflow_props.get(&'base_scene_res_path', '')
            else:
                scene_base = path

            # if the scene already exists, make sure the UID is the asset id,
            # and return
            # XXX this will throw an error if the UID points elsewhere.
            if ResourceLoader.exists(tscn_path):
                if ResourceUID.path_to_uid(tscn_path) != uid:
                    # tscn UID is not the asset id; let's update it
                    _update_resource_uid(
                        tscn_path,
                        ResourceUID.text_to_id(uid),
                    )
                continue

            # The scene does not exist; create a basic one now.
            create_gltf_scene(tscn_path, uid, path, scene_base)

        # if we imported animation tracks, make sure to update the animation
        # library
        elif asset_type == 'ANIMATION':
            post_import_handle_animations(gltf)


func _on_resources_reload(paths):
    log.trace(self, paths)


## Given a GLTF path, return the path to the associated scene file should be
func _gltf_scene_path(gltf_path: String) -> String:
    return str(gltf_path.substr(0, gltf_path.length() - 5), '.tscn')


## Change the UID assigned to a Resource; primarily used for .tscn files
func _update_resource_uid(path: String, id: int):
    log.info(self, 'Update UID ', path, ': ', ResourceUID.id_to_text(id))
    ResourceSaver.set_uid(path, id)
    # The UID change **will not take effect** unless we tell the editor that
    # the file was updated.
    var file_system := get_editor_interface().get_resource_filesystem()
    file_system.update_file(path)


## Run before resource input, this function does the import configuration for
## GLTF files.  It is primarily responsible for checking that the UID is set
## on the proper file (GLTF or TSCN).
func setup_import_config(gltf_path: String) -> void:
    var gltf = GltfWrapper.new(gltf_path)
    var extras = gltf.scene_extras
    log.trace(self, 'scene extras: ', extras)
    var asset_type = extras.get(&'asset_type', &'')
    var asset_id = extras.get(&'asset_id', &'')
    if asset_id == &'':
        return
    var asset_uid = asset_uri(asset_id) if asset_id else ''

    # Given the asset_uid, get the id (int), whether it exists in Godot, and if
    # it exists, what path is associated
    asset_id = ResourceUID.text_to_id(asset_uid)
    var asset_id_exists = ResourceUID.has_id(asset_id)
    var asset_id_path = &'(none)'
    if asset_id_exists:
        asset_id_path = ResourceUID.get_id_path(asset_id)

    var import_config_path = gltf_path + '.import'
    var import_config := ConfigFile.new()
    import_config.load(import_config_path)
    # Set GLTF naming version to 4.5+, otherwise it defaults to 0 which is 4.0
    import_config.set_value('params', 'gltf/naming_version', 2)
    # Allow the GLTF extras to set the root node type.  If none is provided,
    # we'll default to Node3D.
    import_config.set_value(
        'params',
        'nodes/root_type',
        extras.get('root_node_type', 'Node3D'),
    )

    # When handling asset_id collisions, there are two conditions where the UID
    # will be swapped from one asset to another.  They happen when a GLTF asset
    # is converted to a SCENE, or the reverse.

    if asset_type == 'GLTF':
        # Quick check to see if the asset was swapped from a SCENE to a GLTF.
        var tscn_path = _gltf_scene_path(gltf_path)
        if asset_id_exists && asset_id_path == tscn_path:
            # Asset did change; we need to move the UID from the .tscn file,
            # to the GLTF file.  We only do the first step here by assigning
            # a new UID to the .tscn file.  We later set the UID when editing
            # the import config
            _update_resource_uid(
                tscn_path,
                ResourceUID.create_id_for_path(tscn_path),
            )
            ResourceUID.remove_id(asset_id)
            asset_id_exists = false
            log.info(
                self,
                'Moving UID ',
                asset_uid,
                ' from ',
                tscn_path,
                ' to ',
                gltf_path,
            )

        # Handle any other type of UID collision here by returning before we
        # set the UID.
        elif asset_id_exists && asset_id_path != gltf_path:
            log.error(
                self,
                'UID collision on ',
                asset_uid,
                '(',
                asset_id,
                ')',
                '; new file ',
                gltf_path,
                ', existing file ',
                asset_id_path,
            )
            return

        # set the UID in the import config
        import_config.set_value('remap', 'uid', asset_uid)
        log.info(self, gltf_path, ' set UID ', asset_uid)

    elif asset_type == 'SCENE' || asset_type == 'INHERIT':
        # Check to see if the asset was changed from a GLTF to a scene
        var tscn_path = _gltf_scene_path(gltf_path)
        if asset_id_exists && asset_id_path != tscn_path:
            # Asset did change from GLTF to SCENE.  We need to clear the UID
            # from the GLTF file by removing the import config.  During the
            # GLTF import, a new UID will be created for it.  After the GLTF
            # has been imported, we'll create/update the associated TSCN file
            # to have the proper UID.
            DirAccess.remove_absolute(import_config_path)
            ResourceUID.remove_id(asset_id)
            asset_id_exists = false
            log.info(
                self,
                'Moving UID ',
                asset_uid,
                ' from ',
                gltf_path,
                ' to ',
                tscn_path,
            )

        # SCENE UID collision is handled in create_gltf_scene

    elif asset_type == 'ANIMATION':
        # update the import config to save each track off into a dedicated file
        _setup_anim_track_imports(gltf, import_config)

    # save changes to the import config
    log.debug(self, 'writing updated config: ', import_config_path)
    import_config.save(import_config_path)


## Update the ImportConfig for all the animation tracks in a GLTF file.  For
## each track in the GLTF file, configure the import to write the animation
## track to a dedicated .tres file based on the track name.
func _setup_anim_track_imports(gltf: GltfWrapper, import_config: ConfigFile):
    log.debug(self, 'setting up')
    var subresources = import_config.get_value('params', '_subresources', { })
    if 'animations' not in subresources:
        subresources['animations'] = { }
    var animations = subresources['animations']
    if 'meshes' not in subresources:
        subresources['meshes'] = { }
    var meshes = subresources['meshes']

    # Pull the framerate from the GLTF extras.  Note, we do not calculate the
    # FPS from the animation sampler's accessor because of floating point
    # accumulation errors.
    #
    # Instead, our addon in Blender will write frame_rate_ratio, containing
    # [fps, fps_base].  We'll calculate the frame rate from those two values
    # and set them in the import config.
    var frame_rate_ratio = gltf.scene_extras.frame_rate_ratio
    var fps = frame_rate_ratio[0] / frame_rate_ratio[1]
    import_config.set_value('params', 'animation/fps', fps)

    # Configure each animation for individual export to its own resource file
    for animation in gltf.data['animations']:
        # Godot is going to strip these suffixes from the animation names.  We
        # need to do it too, otherwise our .import track names won't match what
        # they expect, and will be ignored.
        # We ignore the looping prefix/suffix checking.  We've moved that to an
        # explicit extra field on the GLTF animation
        var name: String = animation.name
        var stripped_name = gltf.strip_animation_suffix(name)
        if stripped_name != null:
            name = stripped_name

        # setup the base configuration
        var cfg = {
            'save_to_file/enabled'= true,
            'save_to_file/path'= str(
				gltf.path.replace("/export/", "/").get_base_dir(),
                '/',
                normalize_filename(animation.name),
                '.tres',
            ),
            'save_to_file/keep_custom_tracks'= true,
        }

        # Pull loop mode from the extras
        var anim_extras = animation.get('extras', { })
        var loop_mode = anim_extras.get('loop_mode', 'None')
        if loop_mode == 'Ping-Pong':
            cfg['settings/loop_mode'] = Animation.LoopMode.LOOP_PINGPONG
        elif loop_mode == 'Repeat':
            cfg['settings/loop_mode'] = Animation.LoopMode.LOOP_LINEAR
        else:
            cfg['settings/loop_mode'] = Animation.LoopMode.LOOP_NONE

        animations[name] = cfg
        log.debug(self, "save ", name, " to ", cfg['save_to_file/path'])

    # Also, in Blender, we're not able to replace the materials on linked
    # meshes without library overrides before export.  So here, we're just
    # going to disable the import of every mesh (and therefore every material)
    # in the GLTF file.  We disable the import by saying "yes, save this mesh",
    # but don't give a save destination.  It works for now?
    for node in gltf.data.nodes:
        meshes[node.name] = {
            'save_to_file/enabled'= true
        }

    # Store the subresources back into the import config.  This is necessary
    # because we may be creating the dictionary for the first time.
    import_config.set_value('params', '_subresources', subresources)


## Create a new scene, with a single child node that is a scene instance of the
## GLTF path provided.  It will also have the UID provided.
func create_gltf_scene(
        tscn_path: String,
        tscn_uid: String,
        gltf_path: String,
        base_scene_path: String,
):
    log.trace(
        self,
        'tscn_path ',
        tscn_path,
        ', tscn_uid ',
        tscn_uid,
        ', gltf_path ',
        gltf_path,
    )

    log.info(
        self,
        'Creating GLTF scene ',
        tscn_path,
        ', ',
        tscn_uid,
    )

    var id = ResourceUID.text_to_id(tscn_uid)

    # Verify the UID doesn't already point at another file.  If it does, return
    # without creating the intermediate scene
    if ResourceUID.has_id(id):
        var path = ResourceUID.get_id_path(id)
        if path != tscn_path:
            log.error(
                self,
                'UID collision on ',
                tscn_uid,
                '(',
                id,
                ')',
                '; new file ',
                path,
                ', existing file ',
                path,
            )
            return

    # create a scene with a single child node that is the GLTF scene instance
    var root: Node3D = null

    # If no base scene is defined, just make Node3D the root
    if base_scene_path.is_empty():
        root = Node3D.new()

    # Warn if the base scene path doesn't exist
    elif !ResourceLoader.exists(base_scene_path):
        log.error(
            self,
            'Base scene for ',
            gltf_path,
            ' not found: ',
            base_scene_path,
        )
        return

    # Base scene exists, create a new inherited scene from it
    else:
        var base_scene = create_inherited_scene(
            ResourceLoader.load(base_scene_path),
        )
        root = base_scene.instantiate(PackedScene.GEN_EDIT_STATE_MAIN_INHERITED)

    # If the base of the scene isn't the GLTF scene, add the GLTF scene as a
    # scene instance
    if gltf_path != base_scene_path:
        var gltf_scene = ResourceLoader.load(gltf_path).instantiate()
        root.add_child(gltf_scene)
        root.name = gltf_scene.name
        gltf_scene.owner = root

        # if the root is an inherited scene that has an export for the GLTF
        # scene instance, set it now.  This allows the inherited scene script
        # to connect to elements in the GLTF scene.
        if obj_has_export(root, &'gltf_scene_instance'):
            log.debug(self, 'setting gltf scene instance in ', root)
            root.set('gltf_scene_instance', gltf_scene)

    # Pack and save the scene
    var packed_scene := PackedScene.new()
    var result = packed_scene.pack(root)
    if result != OK:
        log.error(self, 'Failed to pack scene ', tscn_path, ': ', result)
        root.free()
        return
    ResourceSaver.save(packed_scene, tscn_path)

    # free the in-memory scene
    root.free()

    # Now set the UID in the .tscn file
    _update_resource_uid(tscn_path, id)


## Post-import of animation tracks, update the associated AnimationLibrary
func post_import_handle_animations(gltf: GltfWrapper):
    # Extract the list of animations from the import config
    var import_config_path = gltf.path + '.import'
    var import_config := ConfigFile.new()
    import_config.load(import_config_path)
    var subresources = import_config.get_value('params', '_subresources', { })
    if 'animations' not in subresources:
        log.warn(
            self,
            'No animation tracks found in ',
            gltf.path,
            ' import config',
        )
        return
    var animations = subresources['animations']

    # Check if we need to add animations to a animation library
    #
    # Note, we do not use the rig_asset_ref to determine animation
    # library name because some animations are done on a generic
    # armature that is linked from a single asset.  Those animations
    # belong in a shared animation library, not a library tied to that
    # specific asset.
    var export_props = gltf.scene_extras.get(&'godot_workflow_props')
    # var anim_lib_path = export_props.get(&'anim_lib_res_path', '')
    var anim_lib: AnimationLibrary

    # if anim_lib_path:
    #     if ResourceLoader.exists(anim_lib_path):
    #         anim_lib = load(anim_lib_path)
    #     else:
    #         anim_lib = AnimationLibrary.new()
    #         anim_lib.resource_path = anim_lib_path
    #     log.debug(self, 'anim_lib ', anim_lib)

    for animation_name in animations:
        var config = animations[animation_name]
        var anim_extras = gltf.get_animation_extras(animation_name)
        var anim_path = config[&'save_to_file/path']
        var anim: Animation = load(anim_path)

        var anim_dirty := false

        # UGH, Godot does not honor the .import loop_mode value on re-import.
        # We have to duplicate the work we did in the import setup here to
        # force the animation track to the proper loop mode.
        var loop_mode = anim_extras.get('loop_mode', 'None')
        if loop_mode == 'Ping-Pong':
            loop_mode = Animation.LoopMode.LOOP_PINGPONG
        elif loop_mode == 'Repeat':
            loop_mode = Animation.LoopMode.LOOP_LINEAR
        else:
            loop_mode = Animation.LoopMode.LOOP_NONE

        if loop_mode != anim.loop_mode:
            anim.loop_mode = loop_mode
            anim_dirty = true

        # If there is a rig asset id, make sure to update the animation track
        # paths to they work properly when the Animation root is set to the
        # imported GLTF scene root.
        var root_uid = asset_uri(anim_extras.get('rig_asset_ref', ''))
        if not root_uid:
            log.error(
                self,
                'No `rig_asset_ref` set on animation `',
                animation_name,
                '`; not added to AnimationLibrary',
            )
            continue

        var root_path = ResourceUID.uid_to_path(root_uid)
        if not root_path:
            log.error(
                self,
                'Invalid `rig_asset_ref` for animation `',
                animation_name,
                ': ',
                root_uid,
                '; not added to AnimationLibrary',
            )
            continue

        # The rig_asset_ref is valid; fix up the animation track paths
        # if necessary.
        anim_dirty = anim_dirty || fixup_animation_tracks(
            anim,
            root_path,
            gltf,
        )

        if anim_dirty:
            ResourceSaver.save(anim)

        log.debug(
            self,
            'rig_asset_ref path: ',
            root_path.get_basename(),
        )
		var anim_lib_path = str(root_path.get_basename().replace("/export/", "/"), '-animlib.tres')
        if ResourceLoader.exists(anim_lib_path):
            anim_lib = load(anim_lib_path)
        else:
            anim_lib = AnimationLibrary.new()
            anim_lib.resource_path = anim_lib_path

        # If we're adding the animations to an animation library, do so now.
        if anim_lib:
            anim_lib.add_animation(anim.resource_name, anim)
            log.debug(
                self,
                'add animation ',
                animation_name,
                ' to ',
                anim_lib_path,
                ': ',
                anim_path,
            )
        var rc = ResourceSaver.save(anim_lib, anim_lib_path)
        log.info(self, 'Save ', anim_lib_path, ' returned ', error_string(rc))


## Go through the tracks of the Animation, and fixup any track path that does
## not match in the GLTF root scene.
## Also sets forced interpolation mode per-channel based on extras in the GLTF
## exports.
## Returns true if changes were made to the Animation
func fixup_animation_tracks(animation: Animation, root_path: String, gltf: GltfWrapper) -> bool:
    log.trace(
        self,
        animation.resource_path,
        ', ',
        root_path,
    )
    if not root_path:
        return false

    # Handle the case where the root path is a .tscn; we really want the .gltf
    # because all AnimationPlayers will have their root node set to the .gltf
    # node.
    if root_path.ends_with('.tscn'):
        var cfg = ConfigFile.new()
        cfg.load(root_path.get_basename() + '.gltf.import')
        root_path = cfg.get_value('remap', 'path')

    # Create an instance of the root scene
    var root_scene: Node3D = ResourceLoader.load(root_path).instantiate()

    # flag to track whether we've modified the animation
    var dirty := false

    # patch up the animation track paths
    for track_idx in animation.get_track_count():
        # only patch up imported tracks; we want to preserve all custom tracks
        # present.
        if not animation.track_is_imported(track_idx):
            continue

        # Get the path for the track
        var track_path: NodePath = animation.track_get_path(track_idx)

        # Get the channel info from the GLTF.  If the channel info contains an
        # interpolation extra, use that to override the track interpolation.
        var channel = gltf.get_animation_channel(
            animation.resource_name,
            track_path,
        )
        var channel_extras = channel.get("extras", { })
        var interpolation = channel_extras.get("interpolation", "")
        if interpolation == "Linear":
            animation.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR)
            dirty = true
            log.info(
                self,
                "Animation ",
                animation.resource_name,
                ", Track ",
                track_path,
                ", forced interpolation mode: Linear",
            )
        elif interpolation == "Step":
            animation.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_NEAREST)
            dirty = true
            log.info(
                self,
                "Animation ",
                animation.resource_name,
                ", Track ",
                track_path,
                ", forced interpolation mode: Step",
            )

        # If the track path is valid in the GLTF scene, nothing to be done
        if root_scene.has_node(track_path):
            # log.trace(self, "animation track path exists: ", track_path)
            continue

        # Track path does not exist; let's try a depth limited search to see if
        # the node path matches any of the nodes within the root scene
        var found = false
        for child in root_scene.get_children():
            if not child.has_node(track_path):
                continue

            # The child has the track path; let's update the track path to be
            # prefixed by the child node name
            var new_path = str(child.name, '/', track_path)
            log.debug(
                self,
                'update animation track path ',
                track_path,
                ': ',
                new_path,
            )
            animation.track_set_path(track_idx, new_path)
            dirty = true
            found = true
            break

        # Show a warning if we weren't able to find a child that matched the
        # track path.  If you see this warning, either the two GLTF files are
        # out of sync, or we need to traverse deeper in the root scene to match
        # the track path.
        if not found:
            log.warn(
                self,
                animation.resource_path.get_file(),
                ': failed to find track path `',
                track_path,
                '` in scene: ',
                root_path,
            )

    # release our instance of the root scene
    root_scene.free()

    # if we made any changes, save the animation
    return dirty


## Convert non-URI asset id strings into uid:// URIs
## Godot uses a special scheme to encode the 64-bit ID, and we don't want to
## duplicate that code on the python side.  Instead Any UID generated on the
## python side will be a str(int) (blender errors ## storing 64-bit int).
static func asset_uri(input: String) -> String:
    if not input:
        return ''
    if input.begins_with('uid://'):
        return input
    var id: int = input.to_int()
    return ResourceUID.id_to_text(id)


## Create a scene instance PackedScene
## This is a workaround for not being able to programmatically create inherited
## scenes from scratch in GDScript.  The approach comes from:
##   https://github.com/godotengine/godot-proposals/issues/3907#issuecomment-1219013739
func create_inherited_scene(inherits: PackedScene, root_name := "Scene") -> PackedScene:
    var scene := PackedScene.new()
    scene._bundled = {
        "names": [root_name],
        "variants": [inherits],
        "node_count": 1,
        "nodes": [-1, -1, 2147483647, 0, -1, 0, 0],
        "conn_count": 0,
        "conns": [],
        "node_paths": [],
        "editable_instances": [],
        "base_scene": 0,
        "version": 3,
    }
    return scene


## Check to see if the Object exports a variable
static func obj_has_export(obj: Object, name: String) -> bool:
    for prop in obj.get_property_list():
        if prop.name == name:
            return prop.usage & PROPERTY_USAGE_EDITOR != 0
    return false


## Ensure imported filenames are all lowercase
static func normalize_filename(part: String) -> String:
    # "someWord" -> "some_Word": a lowercase/digit directly before an uppercase
    var lowercase_then_upper := RegEx.create_from_string("(?<=[a-z0-9])(?=[A-Z])")
    # "CHWord" -> "CH_Word": a run of caps directly before a Capital+lowercase pair
    var acronym_then_capital := RegEx.create_from_string("(?<=[A-Z])(?=[A-Z][a-z])")

    var s := lowercase_then_upper.sub(part, "_", true)
    s = acronym_then_capital.sub(s, "_", true)
    return s.to_lower()
