using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Brutal.ImGuiApi;

namespace KsaChinese
{
    public static class Translator
    {
        private static readonly bool Chinese = SelectLanguage();
        private static readonly Dictionary<string, string> Texts = LoadTexts();
        private static readonly HashSet<string> ReviewedValues = new HashSet<string>(Texts.Values, StringComparer.Ordinal);
        private static readonly PhraseNode Descriptions = BuildDescriptions();
        private static readonly ConcurrentDictionary<string, string> Cache = new ConcurrentDictionary<string, string>(StringComparer.Ordinal);
        private static readonly Regex EnglishRun = new Regex(@"[A-Za-z][A-Za-z0-9 /\-]*[A-Za-z]|[A-Za-z]+", RegexOptions.Compiled);
        private static readonly Regex ProtectedTokens = new Regex(@"\{[^{}]*\}|<[^>]*>|%(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?[a-zA-Z%]", RegexOptions.Compiled);

        private sealed class PhraseNode
        {
            internal readonly Dictionary<char, PhraseNode> Children = new Dictionary<char, PhraseNode>();
            internal string Translation;
        }

        private static PhraseNode BuildDescriptions()
        {
            var root = new PhraseNode();
            var partTranslations = new HashSet<string>(StringComparer.Ordinal);
            foreach (var pair in Texts)
                if (pair.Key.IndexOf("_Prefab_", StringComparison.Ordinal) >= 0)
                    partTranslations.Add(pair.Value);
            foreach (var pair in Texts)
            {
                // 部件编号常与读数拼接；仅识别词典中已审校的完整名称，保留未知编号。
                // 显式显示名也作为完整短语收录，避免型号、加号和数字被拆散。
                bool partName = pair.Key.IndexOf("_Prefab_", StringComparison.Ordinal) >= 0 ||
                    partTranslations.Contains(pair.Value);
                // 海平面和真空读数含括号，不能仅按连续英文字母拆分。
                bool readoutLabel = pair.Key.EndsWith(" (SL)", StringComparison.Ordinal) ||
                    pair.Key.EndsWith(" (Vac)", StringComparison.Ordinal);
                // 长描述可能与名称、读数或其他句子拼接；不收录含格式标记的文本。
                if ((!partName && !readoutLabel && pair.Key.Length < 30) || !Char.IsLetter(pair.Key[0]) ||
                    pair.Key.IndexOfAny(new[] { '{', '<', '%', '#' }) >= 0) continue;
                AddPhrase(root, pair.Key, pair.Value);
                // 同一段文本可能经过测量和绘制入口多次，已审校译文必须保持稳定。
                AddPhrase(root, pair.Value, pair.Value);
            }
            return root;
        }

        private static void AddPhrase(PhraseNode root, string original, string translation)
        {
            var node = root;
            foreach (char character in original)
            {
                char key = Char.ToUpperInvariant(character);
                PhraseNode next;
                if (!node.Children.TryGetValue(key, out next))
                {
                    next = new PhraseNode();
                    node.Children.Add(key, next);
                }
                node = next;
            }
            node.Translation = translation;
        }

        private static bool SelectLanguage()
        {
            // 启动入口仅影响本进程；直接启动时读取补丁的默认语言。
            string choice = Environment.GetEnvironmentVariable("KSA_LANGUAGE");
            if (String.IsNullOrEmpty(choice))
            {
                string path = Path.Combine(AppContext.BaseDirectory, "localization-language.txt");
                choice = File.Exists(path) ? File.ReadAllText(path).Trim() : "en-US";
            }
            return choice.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
        }

        private static Dictionary<string, string> LoadTexts()
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (!Chinese) return result;
            try
            {
                string path = Path.Combine(AppContext.BaseDirectory, "Content", "Core", "Languages", "zh-Hans.ui.json");
                var loaded = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path));
                foreach (var pair in loaded) result[pair.Key] = pair.Value;
            }
            catch (Exception error)
            {
                // 字典缺失时保留英文，避免阻止游戏启动。
                try { File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "localization-error.log"), error.ToString() + Environment.NewLine); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            return result;
        }

        public static string Translate(string text)
        {
            if (!Chinese || String.IsNullOrEmpty(text)) return text;
            // 动态读数可能不断变化，限制缓存大小以免长时间游玩积累内存。
            if (Cache.Count > 16384) Cache.Clear();
            return Cache.GetOrAdd(text, TranslateCore);
        }

        private static string TranslateCore(string text)
        {
            string translated;
            if (Texts.TryGetValue(text, out translated)) return translated;
            if (ReviewedValues.Contains(text)) return text;
            // 隐藏的控件标识、格式占位符与动态数字保持原样。
            int marker = text.IndexOf("##", StringComparison.Ordinal);
            string visible = marker < 0 ? text : text.Substring(0, marker);
            string suffix = marker < 0 ? "" : text.Substring(marker);
            string trimmed = visible.Trim();
            if (trimmed.Length == 0) return text;
            if (Texts.TryGetValue(trimmed, out translated))
                return visible.Substring(0, visible.IndexOf(trimmed, StringComparison.Ordinal)) + translated + visible.Substring(visible.IndexOf(trimmed, StringComparison.Ordinal) + trimmed.Length) + suffix;
            // 只替换已审校词条；例如带数值的“Mass: 10 kg”与带型号的部件名。
            var output = new StringBuilder();
            int previous = 0;
            foreach (Match protectedToken in ProtectedTokens.Matches(visible))
            {
                output.Append(TranslateWords(visible.Substring(previous, protectedToken.Index - previous)));
                output.Append(protectedToken.Value);
                previous = protectedToken.Index + protectedToken.Length;
            }
            output.Append(TranslateWords(visible.Substring(previous)));
            return output.ToString() + suffix;
        }

        private static string TranslateWords(string text)
        {
            // 按最长完整句子匹配，避免拼接的描述因句号、分号或换行而漏译。
            var output = new StringBuilder();
            int previous = 0;
            for (int start = 0; start < text.Length; start++)
            {
                if (start > 0 && IsIdentifierCharacter(text[start - 1])) continue;
                var node = Descriptions;
                string translated = null;
                int end = start;
                for (int cursor = start; cursor < text.Length; cursor++)
                {
                    if (!node.Children.TryGetValue(Char.ToUpperInvariant(text[cursor]), out node)) break;
                    if (node.Translation != null &&
                        (!IsIdentifierCharacter(text[cursor]) || cursor + 1 == text.Length || !IsIdentifierCharacter(text[cursor + 1])))
                    {
                        translated = node.Translation;
                        end = cursor + 1;
                    }
                }
                if (translated == null) continue;
                output.Append(TranslateLabels(text.Substring(previous, start - previous)));
                output.Append(translated);
                previous = end;
                start = end - 1;
            }
            output.Append(TranslateLabels(text.Substring(previous)));
            return output.ToString();
        }

        private static bool IsIdentifierCharacter(char character)
        {
            return Char.IsLetterOrDigit(character) || character == '_' || character == '-' || character == '/';
        }

        private static string TranslateLabels(string text)
        {
            return EnglishRun.Replace(text, match =>
            {
                string word = match.Value.TrimEnd();
                string value;
                return Texts.TryGetValue(word, out value) ? value + match.Value.Substring(word.Length) : match.Value;
            });
        }

        public static ReadOnlySpan<char> TranslateChars(ReadOnlySpan<char> text)
        {
            if (!Chinese || text.IsEmpty) return text;
            return Translate(text.ToString()).AsSpan();
        }

        public static ReadOnlySpan<byte> TranslateBytes(ReadOnlySpan<byte> text)
        {
            if (!Chinese || text.IsEmpty) return text;
            // 保留组合框中以空字符分隔的各选项。
            string original = Encoding.UTF8.GetString(text);
            string[] parts = original.Split('\0');
            bool changed = false;
            for (int i = 0; i < parts.Length; i++)
            {
                string next = Translate(parts[i]);
                changed |= next != parts[i];
                parts[i] = next;
            }
            if (!changed) return text;
            byte[] bytes = Encoding.UTF8.GetBytes(String.Join("\0", parts) + "\0");
            // 原生按钮和菜单依赖末尾的空字符，但跨度长度不包含新增的终止符。
            return bytes.AsSpan(0, bytes.Length - 1);
        }

        public static string TooltipFontPath(string original)
        {
            return Chinese ? Path.Combine(AppContext.BaseDirectory, "Content", "Fonts", "KSA-SimplifiedChinese.ttf") : original;
        }

        public static string KeyName(string original)
        {
            if (!Chinese || String.IsNullOrEmpty(original)) return original;
            // 按键名称仅在绑定显示路径转换，避免把轨道周期 Period 当作句号键。
            return Regex.Replace(original, @"\b(?:RightBracket|LeftBracket|Period|Comma|Semicolon|Apostrophe|Escape|Space|Enter|Backspace|Delete|Insert|PageUp|PageDown|Home|End|Up|Down|Left|Right|Mouse[1-8])\b", match =>
            {
                switch (match.Value)
                {
                    case "RightBracket": return "]";
                    case "LeftBracket": return "[";
                    case "Period": return ".";
                    case "Comma": return ",";
                    case "Semicolon": return ";";
                    case "Apostrophe": return "'";
                    case "Escape": return "Esc";
                    case "Space": return "空格";
                    case "Enter": return "回车";
                    case "Backspace": return "退格";
                    case "Delete": return "删除键";
                    case "Insert": return "插入键";
                    case "PageUp": return "上一页";
                    case "PageDown": return "下一页";
                    case "Home": return "Home";
                    case "End": return "End";
                    case "Up": return "↑";
                    case "Down": return "↓";
                    case "Left": return "←";
                    case "Right": return "→";
                    case "Mouse1": return "鼠标左键";
                    case "Mouse2": return "鼠标右键";
                    case "Mouse3": return "鼠标中键";
                    default: return "鼠标键 " + match.Value.Substring(5);
                }
            });
        }

        public static bool IsWordBoundary(char character, string text, int index)
        {
            if (Char.IsWhiteSpace(character)) return true;
            if (!Chinese) return false;
            // 中文按字换行，句末标点与前一字保留在同一行。
            bool chineseCharacter = character >= '\u3400' && character <= '\u9fff';
            bool punctuation = "，。！？；：、）》】”’".IndexOf(character) >= 0;
            return (chineseCharacter || punctuation) &&
                (index + 1 == text.Length || "，。！？；：、）》】”’".IndexOf(text[index + 1]) < 0);
        }

        public static void DrawCenteredWrappedText(ReadOnlySpan<char> text)
        {
            string translated = Translate(text.ToString());
            var guiText = (ImString)translated;
            float available = ImGui.GetContentRegionAvail().X;
            float width = ImGui.CalcTextSize(guiText, false, -1).X;
            if (width < available && translated.IndexOf('\n') < 0)
            {
                ImGui.SetCursorPosX(ImGui.GetCursorPosX() + (available - width) * 0.5f);
                ImGui.Text(guiText);
            }
            else
            {
                ImGui.TextWrapped(guiText);
            }
        }

        public static string Font(string original)
        {
            return Chinese ? "KSA-SimplifiedChinese" : original;
        }

        public static bool IsChinese()
        {
            return Chinese;
        }

        public static string Native(string key, string original)
        {
            return Translate(original);
        }
    }
}
