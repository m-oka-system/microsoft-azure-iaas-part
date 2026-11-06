"""配布物の検証"""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
# 拡張機能が実行するスクリプト。vm と vmss で同じ内容を二重に持つ
VM_SETUP_TEMPLATE = REPO_ROOT / "labs" / "modules" / "vm" / "setup.sh.tftpl"
VMSS_SETUP_TEMPLATE = REPO_ROOT / "labs" / "modules" / "vmss" / "setup.sh.tftpl"
# 相手のパスを書いた行だけは、ファイルごとに違ってよい
SELF_REFERENCE_MARK = "と同じ内容を持つ"


def drop_self_reference(text: str) -> str:
    """相手のファイルを指す行を取り除く"""
    return "\n".join(line for line in text.splitlines() if SELF_REFERENCE_MARK not in line)


def test_vmとvmssのsetup_tftplは同じ内容である():
    # シンボリックリンクにすると Windows で clone したときに実体を失うため、二重に置いている
    # 片方だけ直すと、VM と VMSS で違う手順が走る
    # 拡張機能は実際に apply するまで動かないため、この食い違いは実機でしか気づけない
    vm_template = VM_SETUP_TEMPLATE.read_text(encoding="utf-8")
    vmss_template = VMSS_SETUP_TEMPLATE.read_text(encoding="utf-8")
    assert drop_self_reference(vm_template) == drop_self_reference(vmss_template)


def test_setup_tftplは互いへの参照を持つ():
    # 二重に置いていることと、両方を直す必要があることを、ファイル自身に書いておく
    # 上の比較は参照の行を除いて行うため、参照が消えても気づけない
    assert "modules/vmss/setup.sh.tftpl" in VM_SETUP_TEMPLATE.read_text(encoding="utf-8")
    assert "modules/vm/setup.sh.tftpl" in VMSS_SETUP_TEMPLATE.read_text(encoding="utf-8")
