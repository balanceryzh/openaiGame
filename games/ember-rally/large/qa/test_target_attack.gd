extends SceneTree
var game
var failures:=[]
func _initialize():call_deferred("run")
func check(ok:bool,label:String):
 print("PASS " if ok else "FAIL ",label)
 if not ok:failures.append(label)
func fixture():
 game.reset_game();game.set_process(false);game.demo=false;game.state="play"
 game.audio_controller.settings_path="";game.set_volume(0)
 game.hero=Vector2(3700,2750);game.enemies.clear();game.sleeping_enemies.clear();game.allies.clear();game.camps.clear();game.corpses.clear();game.gems.clear();game.bullets.clear()
 game.spawn_cd=9999;game.necromancers.spawn_cooldown=9999;game.director.entrance_cooldown=9999;game.needed=1000000
func run():
 game=load("res://large/battle_logic.gd").new();root.add_child(game);fixture()
 var start:Vector2=game.hero
 Input.action_press("battle_move_right")
 var false_attacks:=0
 for i in range(120):
  game.simulate(1.0/60)
  if game.attack_age>=0:false_attacks+=1
 Input.action_release("battle_move_right")
 check(false_attacks==0,"120 no-target movement frames never enter hero attack")
 check(game.hero.distance_to(start)>100,"No-target movement advances hero")
 fixture()
 var e:Dictionary=game.make_enemy(game.hero+Vector2(40,0),"undead");e.hp=1000;e.max=1000
 var original:float=e.hp
 var observed_damage:=0.0
 for i in range(10):
  e.p=game.hero+Vector2(40,0)
  game.simulate(1.0/60)
 observed_damage=original-e.hp
 check(e.hp<original,"Valid in-range target receives normal hero strike damage")
 fixture()
 e=game.make_enemy(game.hero+Vector2(game.reach+23,0),"undead")
 game.simulate(1.0/60)
 check(game.attack_age<0,"Target inside search radius but outside actual reach does not trigger attack")
 print("TARGET_ATTACK_RESULT ",JSON.stringify({"failures":failures,"damage_observed":observed_damage}))
 game.audio_controller.set_process(false);game.audio_controller.stop_effects();game.music.stop()
 quit(0 if failures.is_empty() else 1)
