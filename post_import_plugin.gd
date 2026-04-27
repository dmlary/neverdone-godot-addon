@tool
extends EditorScenePostImportPlugin

var log := Logrr.new()


func _pre_process(scene: Node) -> void:
    # enable tons of debug info
    log.set_level(self, Logrr.Level.TRACE)
    log.trace(self, scene)


func _post_process(scene: Node) -> void:
    log.trace(self, scene)

    # XXX when importing animation assets, we save the animations to their
    # .tres files, but we still generate a .scn containing all the nodes.  See
    # about not generating a node tree when we're importing Animations

    var queue = [scene]
    while !queue.is_empty():
        var node: Node = queue.pop_front()
        log.trace(self, 'node ', node)

        # depth first traversal, and we'll need to be careful if we want to
        # prune children after replacing the current node.
        queue = node.get_children() + queue

        var node_extras = node.get_meta('extras', { })

        if node is Node3D and 'asset_ref' in node_extras:
            var asset_ref = BlenderWorkflowPlugin.asset_uri(
                node_extras['asset_ref'],
            )

            var scene_instance = ResourceLoader.load(asset_ref).instantiate()
            _replace_node(node, scene_instance)

            # Set any properties on the scene that were set in the GLTF extras
            var scene_props = node_extras.get('godot_scene_props', { })
            for prop_name in scene_props:
                _set_scene_property(
                    scene_instance,
                    prop_name,
                    scene_props[prop_name],
                )

            # we've swapped out node, so we probably shouldn't be doing anything
            # else for this node.
            continue
        elif node and 'physics_body' in node_extras:
            var body_info = node_extras.physics_body
            var body = ClassDB.instantiate(body_info.type)
            _replace_node(node, body)

        elif node and 'collision_shape' in node_extras:
            var shape_info: Dictionary = node_extras['collision_shape']
            var collision_shape = CollisionShape3D.new()
            _replace_node(node, collision_shape)

            if shape_info['type'] == 'PRIMITIVE':
                if shape_info['shape'] == 'BOX':
                    var size = shape_info['size']
                    size = Vector3(size[0], size[2], size[1])
                    var center = _vec3_from_blender(shape_info['center'])

                    # Note: we're not doing `+Y Up` in collision_shape export
                    var shape = BoxShape3D.new()
                    shape.size = size
                    collision_shape.shape = shape
                    collision_shape.position += collision_shape.transform.basis * center
                elif shape_info['shape'] == 'CAPSULE':
                    var shape := CapsuleShape3D.new()
                    shape.radius = shape_info['radius']
                    shape.height = shape_info['height']
                    collision_shape.shape = shape
                else:
                    log.warn(
                        self,
                        'Unsupported primitive type in ',
                        _oot_path(node),
                        ': ',
                        shape_info,
                    )
                    continue
            elif shape_info['type'] == 'MESH':
                collision_shape.shape = node.mesh.create_trimesh_shape()
            else:
                log.warn(
                    self,
                    'Unsupported collision shape type in ',
                    _oot_path(node),
                    ': ',
                    shape_info,
                )
                continue

            log.info(
                self,
                'Replaced ',
                _oot_path(node),
                ' with collision shape ',
                node_extras['collision_shape'],
            )

        # The node represents a Path3D.  We will create a Curve3D based on the
        # values in `path_points`, and add it to a Path3D.  We will replace the
        # current node with that Path3D.
        elif node and 'path_points' in node_extras:
            var curve := Curve3D.new()
            for point: Array in node_extras.path_points:
                # In Blender, bezier curve in/out values are in local space,
                # and that's what is stored in each point Array: 
                # [point, in, out]
                # In Godot, the in/out values are vectors relative to the
                # point.  We're converting local space to point-relative here
                # when we add the point to the Curve3D.
                var pos := _vec3_from_blender(point[0])
                curve.add_point(
                    pos,
                    _vec3_from_blender(point[1]) - pos,
                    _vec3_from_blender(point[2]) - pos,
                )

            var path := Path3D.new()
            path.curve = curve

            _replace_node(node, path)

        elif node is MeshInstance3D:
            var mesh: Mesh = node.mesh
            for i in mesh.get_surface_count():
                # Grab the material used for the surface
                var mat: Material = mesh.surface_get_material(i)

                # Check to see if the material is a placeholder material.
                # We add an `asset_ref` custom property to the placeholder
                # materials we create during GLTF export in Blender.  Check
                # the material's meta `extras` for `asset_ref` to see if it
                # is a placeholder.
                var mat_extras = mat.get_meta('extras', { })
                var asset_ref = mat_extras.get('asset_ref', &'')
                if not asset_ref:
                    continue
                asset_ref = BlenderWorkflowPlugin.asset_uri(asset_ref)

                # Check to see if the `asset_ref` references a real file
                if !ResourceLoader.exists(asset_ref):
                    log.error(
                        self,
                        'Invalid asset-ref in material ',
                        mat.resource_path,
                        ': ',
                        asset_ref,
                    )
                    continue

                # Load the intended material, and update the surface material
                # and material name
                var new_mat: Material = load(asset_ref)
                var new_name = new_mat.resource_path.get_file().get_basename()
                mesh.surface_set_material(i, new_mat)
                mesh.surface_set_name(i, new_name)
                log.debug(
                    self,
                    _oot_path(node),
                    ': set surface ',
                    i,
                    ' material: ',
                    new_mat.resource_path,
                )


## Get the path of a node, even when it's out-of-tree (OOT)
func _oot_path(node: Node) -> String:
    var out = node.name
    node = node.get_parent()
    while node != null:
        out = str(node.name, '/', out)
        node = node.get_parent()
    return out


func _internal_process(category: int, base_node: Node, node: Node, resource: Resource) -> void:
    log.debug(
        self,
        'category ',
        category,
        ', base_node ',
        base_node,
        ', node ',
        node,
        ', resource ',
        resource,
    )


## Convert Array containing x, y, z coords from Blender into Godot Vector3.
## Note: this function does the Y-Up, and Z changes
func _vec3_from_blender(point: Array) -> Vector3:
    return Vector3(point[0], point[2], -point[1])


## Replace the supplied node with another node
##
## This function will replace the supplied node with another node.  It will
## also migrate all children of the original node to the replacement node.
##
## Arguments:
##  node: original node
##  other: replacement node
func _replace_node(node, other):
    node.add_sibling(other)
    log.trace(
        self,
        'replace node ',
        _oot_path(node),
        ' with ',
        other,
    )
    other.transform = node.transform
    other.owner = node.owner
    node.get_parent().remove_child(node)
    other.name = node.name

    # preserve the extras to make debugging easier
    var extras: Dictionary = node.get_meta("extras", null)
    if extras:
        other.set_meta("extras", extras)

    for child in node.get_children():
        node.remove_child(child)
        child.owner = null
        other.add_child(child)
        child.owner = other.owner

    node.queue_free()


## Set a property on a scene instance, doing any needed conversions from the
## value type to the property type
func _set_scene_property(scene: Object, prop_name: String, value: Variant):
    var property: Dictionary
    for p in scene.get_property_list():
        if p.name == prop_name:
            property = p
            break

    if not property:
        log.error(
            self,
            'property `',
            prop_name,
            '` not found on ',
            _oot_path(scene),
        )
        return

    log.warn(self, property)
    if property.type == TYPE_NODE_PATH:
        if value:
            value = NodePath(value)
    elif property.type == TYPE_BOOL:
        value = int(value) == 1

    log.debug(
        self,
        'set ',
        _oot_path(scene),
        ':',
        prop_name,
        ' = `',
        value,
        '`',
    )
    scene.set(prop_name, value)
