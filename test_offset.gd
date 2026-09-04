extends SceneTree

func _init():
    var s = Sprite3D.new()
    var tex = ImageTexture.create_from_image(Image.create_empty(32, 40, false, Image.FORMAT_RGBA8))
    s.texture = tex
    s.pixel_size = 0.05
    s.offset = Vector2(0, 20)
    print("Offset (0, 20) AABB: ", s.get_aabb())
    s.offset = Vector2(0, -20)
    print("Offset (0, -20) AABB: ", s.get_aabb())
    s.offset = Vector2(0, 0)
    print("Offset (0, 0) AABB: ", s.get_aabb())
    quit()
