import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import struct

ROOT = Path(__file__).resolve().parent.parent


def sha(data):
    return hashlib.sha256(data).hexdigest()


def make_delta(original, patched):
    # 固定锚点定位相同字节，差分仅保存复制指令和实际新增内容。
    width = 32
    anchors = {}
    for offset in range(0, len(original) - width + 1, 16):
        anchors.setdefault(original[offset:offset + width], offset)
    output = bytearray(b'KSAZH001' + struct.pack('<I', len(patched)))
    cursor = 0
    literal = 0
    while cursor + width <= len(patched):
        offset = anchors.get(patched[cursor:cursor + width])
        if offset is None:
            cursor += 1
            continue
        if cursor > literal:
            data = patched[literal:cursor]
            output.extend(b'\x01' + struct.pack('<I', len(data)) + data)
        length = width
        limit = min(len(original) - offset, len(patched) - cursor)
        while length < limit and original[offset + length] == patched[cursor + length]:
            length += 1
        output.extend(b'\x00' + struct.pack('<II', offset, length))
        cursor += length
        literal = cursor
    if literal < len(patched):
        data = patched[literal:]
        output.extend(b'\x01' + struct.pack('<I', len(data)) + data)
    output.extend(b'\xff')
    return gzip.compress(bytes(output), mtime=0)


def apply_delta(original, delta):
    data = gzip.decompress(delta)
    assert data[:8] == b'KSAZH001'
    size = struct.unpack_from('<I', data, 8)[0]
    cursor = 12
    output = bytearray()
    while data[cursor] != 255:
        kind = data[cursor]
        cursor += 1
        if kind == 0:
            offset, length = struct.unpack_from('<II', data, cursor)
            cursor += 8
            assert offset + length <= len(original)
            output.extend(original[offset:offset + length])
        elif kind == 1:
            length = struct.unpack_from('<I', data, cursor)[0]
            cursor += 4
            output.extend(data[cursor:cursor + length])
            cursor += length
        else:
            raise ValueError('未知差分指令')
    assert cursor == len(data) - 1 and len(output) == size
    return bytes(output)


def main():
    parser = argparse.ArgumentParser(description='从本地已验证的汉化工作区生成仅含差分与译文的发布包')
    parser.add_argument('workspace', type=Path)
    args = parser.parse_args()
    source = args.workspace.resolve()
    manifest = json.loads((source / '汉化补丁/manifest.json').read_text(encoding='utf-8'))
    package = source / '汉化补丁/文件'
    originals = source / '汉化备份/原始文件'
    distribution = {'gameBuild': manifest['gameBuild'], 'translatedEntries': manifest['translatedEntries'],
                    'nativeEntries': manifest['nativeEntries'], 'originalHashes': manifest['originalHashes'],
                    'patchedHashes': {}, 'files': {}, 'deltas': {},
                    'localFont': 'Content/Fonts/KSA-SimplifiedChinese.ttf'}
    for relative, expected in manifest['patchedHashes'].items():
        if relative == distribution['localFont']:
            continue
        patched = (package / relative).read_bytes()
        assert sha(patched) == expected, f'补丁校验失败：{relative}'
        distribution['patchedHashes'][relative] = expected
        if relative in manifest['originalHashes']:
            original = (originals / relative).read_bytes()
            assert sha(original) == manifest['originalHashes'][relative]
            delta = make_delta(original, patched)
            assert apply_delta(original, delta) == patched, f'差分重建失败：{relative}'
            destination = 'patches/' + relative.replace('/', '__') + '.ksadelta.gz'
            path = ROOT / destination
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(delta)
            distribution['deltas'][relative] = {'path': destination, 'sha256': sha(delta)}
            print(f'{relative}: {len(patched):,} -> {len(delta):,} bytes')
        else:
            destination = 'payload/' + relative
            path = ROOT / destination
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(package / relative, path)
            assert sha(path.read_bytes()) == expected
            distribution['files'][relative] = destination
    (ROOT / 'manifest.json').write_text(json.dumps(distribution, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (ROOT / 'src').mkdir(exist_ok=True)
    for path in sorted((source / 'scripts').glob('translations*.tsv')):
        shutil.copyfile(path, ROOT / 'src' / path.name)
    shutil.copyfile(source / 'scripts/ChineseLocalization.cs', ROOT / 'src/ChineseLocalization.cs')
    # 发布报告只保留验证结果，不携带游戏路径、游戏日志或原始资源目录。
    (ROOT / 'reports').mkdir(exist_ok=True)
    for name in ('运行检查.json', '部件覆盖报告.json', '描述覆盖报告.json'):
        shutil.copyfile(source / '汉化补丁' / name, ROOT / 'reports' / name)


if __name__ == '__main__':
    main()
