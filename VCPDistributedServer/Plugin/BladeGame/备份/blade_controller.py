import sys
import json
import os
import subprocess
import time
import threading
import uuid
import requests

# ---------------------------------------------------------
# 配置路径与常量
# ---------------------------------------------------------
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(CURRENT_DIR, "game_state.json")
GUI_SCRIPT = os.path.join(CURRENT_DIR, "blade_gui.py")

# 异步回调配置 (由VCP主服务注入)
CALLBACK_BASE_URL = os.environ.get("CALLBACK_BASE_URL", "")
PLUGIN_NAME_FOR_CALLBACK = os.environ.get("PLUGIN_NAME_FOR_CALLBACK", "BladeGame")

# 轮询配置
POLL_INTERVAL = 0.5  # 500ms
POLL_TIMEOUT = 300   # 5分钟超时

# 动作定义与消耗
MOVES = {
    "Charge": {"cost": 0, "type": "buff", "level": 0, "name": "蓄势"},
    "Slash": {"cost": 0, "type": "attack", "level": 1, "dmg": 1, "name": "斩击"},
    "LightStep": {"cost": 1, "type": "attack", "level": 2, "dmg": 2, "name": "轻霜踏雪"},
    "PlumBlossom": {"cost": 2, "type": "attack", "level": 3, "dmg": 4, "heal": 1, "name": "寒梅逐鹿"},
    "Flash": {"cost": 3, "type": "attack", "level": 4, "dmg": 9, "name": "回光无影"},
    "Block": {"cost": 0, "type": "defense", "level": 0, "name": "御剑格挡"},
    "Taiji": {"cost": 0, "type": "defense", "level": 0, "name": "太极两仪"}
}

def load_state():
    if not os.path.exists(STATE_FILE):
        return None
    try:
        with open(STATE_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    except:
        return None

def save_state(data):
    with open(STATE_FILE, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

def launch_gui():
    """启动独立的GUI进程，不随本脚本退出而关闭"""
    if sys.platform == 'win32':
        DETACHED_PROCESS = 0x00000008
        subprocess.Popen([sys.executable, GUI_SCRIPT], creationflags=DETACHED_PROCESS, shell=False, close_fds=True)
    else:
        subprocess.Popen([sys.executable, GUI_SCRIPT], start_new_session=True, close_fds=True)

def resolve_turn(state, ai_action_key):
    """
    核心战斗逻辑结算
    """
    user_action_key = state['user_input']
    
    # 获取动作数据
    ai_move = MOVES.get(ai_action_key)
    user_move = MOVES.get(user_action_key)
    
    if not ai_move:
        return "Error: AI动作为空或非法"
    
    # 扣除能量
    state['ai_energy'] -= ai_move['cost']
    state['user_energy'] -= user_move['cost']
    
    # 记录本回合动作名称
    log_msg = f"第 {state['turn']} 回合: AI[{ai_move['name']}] vs 用户[{user_move['name']}]。"
    
    # --- 结算逻辑 ---
    ai_dmg_deal = 0
    user_dmg_deal = 0
    ai_heal = 0
    user_heal = 0
    
    # 1. 处理蓄势 (获得能量)
    if ai_action_key == "Charge":
        state['ai_energy'] = min(6, state['ai_energy'] + 1)
    if user_action_key == "Charge":
        state['user_energy'] = min(6, state['user_energy'] + 1)

    # 2. 攻击判定 (拼刀逻辑)
    ai_attack_success = False
    user_attack_success = False
    
    if ai_move['type'] == 'attack':
        if user_move['type'] == 'attack':
            if ai_move['level'] > user_move['level']:
                ai_attack_success = True
                log_msg += " AI招式更胜一筹，打断了用户！"
            elif user_move['level'] > ai_move['level']:
                user_attack_success = True
                log_msg += " 用户招式凌厉，打断了AI！"
            else:
                log_msg += " 双方剑锋相交，不论伯仲！"
                if ai_action_key == 'PlumBlossom': ai_heal = ai_move['heal']
                if user_action_key == 'PlumBlossom': user_heal = user_move['heal']
        else:
            ai_attack_success = True
            
    if user_move['type'] == 'attack':
        if ai_move['type'] != 'attack':
            user_attack_success = True

    # 3. 计算原始伤害
    if ai_attack_success:
        ai_dmg_deal = ai_move['dmg']
        if 'heal' in ai_move: ai_heal = ai_move['heal']
        
    if user_attack_success:
        user_dmg_deal = user_move['dmg']
        if 'heal' in user_move: user_heal = user_move['heal']
        
    # 4. 防御结算
    if user_action_key == 'Block' and ai_attack_success:
        original = ai_dmg_deal
        ai_dmg_deal = max(0, ai_dmg_deal - 4)
        if ai_dmg_deal < original:
            log_msg += " 用户格挡了部分伤害。"
            
    if user_action_key == 'Taiji' and ai_attack_success:
        if ai_action_key == 'Flash':
            ai_dmg_deal = 0
            log_msg += " 用户太极化解了回光无影！"
    
    if ai_action_key == 'Block' and user_attack_success:
        original = user_dmg_deal
        user_dmg_deal = max(0, user_dmg_deal - 4)
        if user_dmg_deal < original:
            log_msg += " AI格挡了部分伤害。"

    if ai_action_key == 'Taiji' and user_attack_success:
        if user_action_key == 'Flash':
            user_dmg_deal = 0
            log_msg += " AI太极化解了回光无影！"

    # 5. 应用数值
    state['ai_hp'] = min(6, state['ai_hp'] + ai_heal - user_dmg_deal)
    state['user_hp'] = min(6, state['user_hp'] + user_heal - ai_dmg_deal)
    
    turn_result = f"结果: AI造成{ai_dmg_deal}伤害(回复{ai_heal})，用户造成{user_dmg_deal}伤害(回复{user_heal})。"
    
    # 更新状态
    state['turn'] += 1
    state['user_ready'] = False
    state['last_ai_move'] = ai_action_key
    state['last_user_move'] = user_action_key
    state['last_log'] = log_msg + " " + turn_result
    
    # 检查游戏结束
    game_over_msg = ""
    if state['ai_hp'] <= 0 and state['user_hp'] <= 0:
        state['game_over'] = True
        game_over_msg = "双方力竭倒地，平局！"
    elif state['ai_hp'] <= 0:
        state['game_over'] = True
        game_over_msg = "AI败北，恭喜大侠获胜！"
    elif state['user_hp'] <= 0:
        state['game_over'] = True
        game_over_msg = "胜负已分，AI获胜！"
        
    if state['game_over']:
        state['last_log'] += " " + game_over_msg

    save_state(state)
    return f"{log_msg} {turn_result} {game_over_msg} 当前状态: AI HP:{state['ai_hp']}/EN:{state['ai_energy']}, User HP:{state['user_hp']}/EN:{state['user_energy']}。该回合已结束，请等待用户下一回合决策。"


def poll_and_callback(request_id, ai_action, callback_url):
    """
    后台轮询线程：等待用户操作完成，然后执行回调
    """
    start_time = time.time()
    
    while True:
        # 超时检查
        if time.time() - start_time > POLL_TIMEOUT:
            try:
                callback_payload = {
                    "requestId": request_id,
                    "status": "timeout",
                    "result": "等待用户操作超时（5分钟），请重新发起回合。"
                }
                requests.post(callback_url, json=callback_payload, timeout=10)
            except:
                pass
            return
        
        # 读取状态
        state = load_state()
        if not state:
            time.sleep(POLL_INTERVAL)
            continue
            
        # 检查游戏是否已结束
        if state.get('game_over'):
            try:
                callback_payload = {
                    "requestId": request_id,
                    "status": "success",
                    "result": f"游戏已结束。{state.get('last_log', '')}"
                }
                requests.post(callback_url, json=callback_payload, timeout=10)
            except:
                pass
            return
        
        # 检查用户是否已准备好
        if state.get('user_ready'):
            # 用户已操作，执行回合结算
            current_en = state['ai_energy']
            needed_en = MOVES.get(ai_action, {'cost': 0})['cost']
            
            if current_en < needed_en:
                ai_action = "Charge"
            
            result_text = resolve_turn(state, ai_action)
            
            # 发起回调
            try:
                callback_payload = {
                    "requestId": request_id,
                    "status": "success",
                    "result": result_text,
                    "action": ai_action
                }
                requests.post(callback_url, json=callback_payload, timeout=10)
            except Exception as e:
                # 回调失败，尝试记录
                print(f"Callback failed: {e}", file=sys.stderr)
            
            return
        
        # 继续等待
        time.sleep(POLL_INTERVAL)


def main():
    # 读取 stdin
    try:
        input_data = sys.stdin.read()
        request = json.loads(input_data)
    except Exception as e:
        request = {}

    command = request.get('command')
    
    # 构建响应
    response = {"status": "success", "result": ""}

    if command == "StartGame":
        maid_name = request.get('maid', 'AI')
        
        # 初始化状态
        initial_state = {
            "maid_name": maid_name,
            "turn": 1,
            "ai_hp": 5,
            "ai_energy": 0,
            "user_hp": 5,
            "user_energy": 0,
            "game_over": False,
            "user_ready": False,
            "user_input": None,
            "last_ai_move": None,
            "last_user_move": None,
            "last_log": "游戏开始！请出招。"
        }
        save_state(initial_state)
        
        # 启动GUI
        launch_gui()
        
        response["result"] = f"游戏GUI已启动，对手是 {maid_name}。初始状态：双方5血0气。请等待用户在GUI中选择招式后，调用 PlayTurn 进行对战。"

    elif command == "PlayTurn":
        state = load_state()
        if not state:
            response["status"] = "error"
            response["result"] = "错误：游戏尚未创建，请先调用 StartGame。"
        elif state['game_over']:
            response["result"] = f"游戏已结束。{state['last_log']}"
        else:
            # 严格校验 action 参数（修复：防止参数缺失时静默降级）
            ai_action = request.get('action')
            if not ai_action:
                response["status"] = "error"
                response["result"] = f"错误：action 参数缺失。必须提供以下值之一: {list(MOVES.keys())}"
            elif ai_action not in MOVES:
                response["status"] = "error"
                response["result"] = f"错误：action 参数非法 ('{ai_action}')。可选值: {list(MOVES.keys())}"
            
            else:
                # 生成唯一请求ID
                request_id = str(uuid.uuid4())[:8]
                
                # 将AI的预选动作存入状态（可选，用于调试）
                state['pending_ai_action'] = ai_action
                save_state(state)
                
                # 检查回调URL是否可用
                if CALLBACK_BASE_URL:
                    callback_url = f"{CALLBACK_BASE_URL}/{PLUGIN_NAME_FOR_CALLBACK}/{request_id}"
                    
                    # 启动后台轮询线程
                    polling_thread = threading.Thread(
                        target=poll_and_callback,
                        args=(request_id, ai_action, callback_url),
                        daemon=False
                    )
                    polling_thread.start()
                    
                    # 立即返回占位符响应
                    response["result"] = (
                        f"⚔️ AI已选择招式，等待大侠出招...\n"
                        f"请在GUI窗口中选择你的招式，结果将自动更新。\n\n"
                        f"{{{{VCP_ASYNC_RESULT::BladeGame::{request_id}}}}}"
                    )
                    
                    # ✅ 关键修复：先打印响应让VCP收到占位符
                    print(json.dumps(response))
                    sys.stdout.flush()
                    
                    # 然后再阻塞等待线程完成
                    polling_thread.join(timeout=310)
                    
                    # 线程结束后直接退出，不再重复打印
                    sys.exit(0)
                else:
                    # 降级为同步模式（兼容旧逻辑）
                    if not state.get('user_ready'):
                        response["result"] = "SYSTEM_WAIT: 用户尚未在GUI中输入指令。请回复用户'请大侠出招'，并等待用户操作完成后再次调用此工具。"
                    else:
                        current_en = state['ai_energy']
                        needed_en = MOVES.get(ai_action, {'cost': 0})['cost']
                        
                        if current_en < needed_en:
                            ai_action = "Charge"
                        
                        result_text = resolve_turn(state, ai_action)
                        response["result"] = result_text

    else:
        response["status"] = "error"
        response["result"] = f"未知指令: {command}"

    print(json.dumps(response))
    
    # 如果启动了后台线程，主进程需要等待
    # 但为了不阻塞VCP，我们让主进程在打印响应后继续运行
    # 后台线程会自行完成回调后退出

if __name__ == "__main__":
    main()