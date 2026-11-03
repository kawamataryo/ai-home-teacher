import UIKit

/// プレビュー・ギャラリー・テストで使う show_board のサンプル入力（Claude が返す形そのまま）。
enum BoardSamples {
    static let photoID = "sample-photo"

    static let json: [BoardComponent.Kind: String] = [
        .stepCards: """
        {"title":"割合の問題、どう考える？","component":{"type":"step_cards","steps":[
          {"heading":"何を聞かれている？","detail":"「もとにする量」がいくつかを聞かれているよ。"},
          {"heading":"どこを見る？","detail":"「60人は全体の40%」の文。60人が「くらべる量」だね。"},
          {"heading":"考え方","detail":"くらべる量 ÷ 割合 ＝ もとにする量。40%を小数にすると？"},
          {"heading":"やってみよう","detail":"60 ÷ □ を計算すると、何人になるかな？"}]}}
        """,
        .numberLine: """
        {"title":"0.75 はどこかな？","component":{"type":"number_line","min":0,"max":1,"step":0.25,"unit":"",
          "marks":[{"value":0.5,"label":"1/2"},{"value":0.75,"label":"？"}],
          "ranges":[{"from":0.5,"to":0.75,"label":"0.25"}]}}
        """,
        .areaDiagram: """
        {"title":"平均を面積図で考えよう","component":{"type":"area_diagram","parts":[
          {"width":3,"height":80,"label":"3人の合計","width_label":"3人","height_label":"80点"},
          {"width":2,"height":65,"label":"2人の合計","width_label":"2人","height_label":"65点"}],
          "total_label":"合わせて5人。平均は？"}}
        """,
        .segmentDiagram: """
        {"title":"兄と弟のお金をくらべよう","component":{"type":"segment_diagram","bars":[
          {"name":"兄","segments":[{"length":3,"label":"弟と同じ"},{"length":2,"label":"200円"}],"total_label":"？円"},
          {"name":"弟","segments":[{"length":3,"label":"？円"}],"total_label":""}]}}
        """,
        .table: """
        {"title":"ともなって変わる量","component":{"type":"table",
          "headers":["だんの数（だん）","1","2","3","4","5"],
          "rows":[["まわりの長さ（cm）","4","8","12","？",""]],
          "highlight_cells":[{"row":0,"column":4}]}}
        """,
        .barChart: """
        {"title":"6月と7月のちがいを読み取ろう","component":{"type":"bar_chart","unit":"mm","bars":[
          {"label":"4月","value":120,"highlighted":false},{"label":"5月","value":135,"highlighted":false},
          {"label":"6月","value":210,"highlighted":true},{"label":"7月","value":160,"highlighted":true},
          {"label":"8月","value":95,"highlighted":false}]}}
        """,
        .highlightImage: """
        {"title":"ここを見てみよう","component":{"type":"highlight_image","image_id":"sample-photo","regions":[
          {"x":0.08,"y":0.30,"width":0.84,"height":0.17,"label":"聞かれていること"},
          {"x":0.55,"y":0.52,"width":0.35,"height":0.12,"label":"単位に注目"}]}}
        """,
        .essayOutline: """
        {"title":"作文の組み立て","component":{"type":"essay_outline","theme":"夏休みの思い出",
          "sections":[
          {"heading":"はじめ","points":["おばあちゃんの家に行った","いちばん心に残ったこと"]},
          {"heading":"なか","points":["川でカニをつかまえた","最初はこわかった","？（そのときの気持ち）"]},
          {"heading":"おわり","points":["また行きたい","？"]}]}}
        """,
        .vennDiagram: """
        {"title":"人数を円で分けよう","component":{"type":"venn_diagram","universe_label":"クラス 32人",
          "left_label":"犬 12人","left_only":"犬だけ ？人","right_label":"ねこ 9人","right_only":"ねこだけ ？人",
          "both":"両方 4人","neither":"どちらも ？人"}}
        """,
        .timeline: """
        {"title":"時間の流れを順に見よう","component":{"type":"timeline","events":[
          {"time":"3時50分","label":"学校を出る","after":"歩いて15分"},
          {"time":"？","label":"図書館に着く","after":"本を読む40分"},
          {"time":"？","label":"図書館を出る","after":"歩いて10分"},
          {"time":"？","label":"公園に着く","after":""}]}}
        """,
        .percentBar: """
        {"title":"25%引きを帯で見よう","component":{"type":"percent_bar","base_label":"もとの値段 1200円",
          "parts":[{"percent":75,"label":"はらう分","amount":"？円"},{"percent":25,"label":"25%引き","amount":"？円"}]}}
        """,
    ]

    static func content(_ kind: BoardComponent.Kind) -> BoardContent {
        BoardTools.content(toolName: BoardTools.showBoardName, input: Data(json[kind]!.utf8))
    }

    /// render_svg のサンプル（図形の問題：三角形の角）。
    static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 460">
      <style>
        .edge{fill:none;stroke:#f5f5f5;stroke-width:5;stroke-linejoin:round;stroke-dasharray:1600;stroke-dashoffset:1600;animation:draw 1.6s ease-out forwards}
        .arc{fill:none;stroke-width:4}
        .t{font-family:-apple-system,sans-serif;font-weight:700;font-size:34px}
        .q{animation:blink 1.2s ease-in-out 1.6s infinite alternate}
        @keyframes draw{to{stroke-dashoffset:0}}
        @keyframes blink{from{opacity:1}to{opacity:.35}}
      </style>
      <polygon class="edge" points="120,400 680,400 300,80"/>
      <path class="arc" stroke="#ffe066" d="M190,400 A70,70 0 0 0 157,338"/>
      <path class="arc" stroke="#8fd0ff" d="M610,400 A70,70 0 0 1 621,361"/>
      <path class="arc" stroke="#ff9eb3" d="M268,134 A62,62 0 0 0 348,120"/>
      <text class="t" x="200" y="372" fill="#ffe066">60°</text>
      <text class="t" x="545" y="380" fill="#8fd0ff">40°</text>
      <text class="t q" x="285" y="190" fill="#ff9eb3">？</text>
      <text class="t" x="96" y="445" fill="#f5f5f5">A</text>
      <text class="t" x="690" y="445" fill="#f5f5f5">B</text>
      <text class="t" x="290" y="62" fill="#f5f5f5">C</text>
    </svg>
    """

    static let svgJSON: String = {
        let input = RenderSVGInput(svg: svg, caption: "三角形の3つの角を合わせると何度だったかな？")
        return String(decoding: try! JSONEncoder().encode(input), as: UTF8.self)
    }()

    static var svgContent: BoardContent {
        BoardTools.content(toolName: BoardTools.renderSVGName, input: Data(svgJSON.utf8))
    }

    /// デコードに失敗する入力（文字での代替表示の確認用）。
    static let brokenJSON = """
    {"title":"この図は読めない","component":{"type":"pie_chart","note":"円グラフで半分が赤"}}
    """

    /// 写真の代わりに描くプリント風の画像。
    @MainActor static let photo: UIImage = {
        let size = CGSize(width: 1200, height: 900)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.97, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 52), .foregroundColor: UIColor.darkGray]
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.darkGray]
            ("問題 3" as NSString).draw(at: CGPoint(x: 100, y: 120), withAttributes: title)
            ("クラスの60人は、学年全体の40%です。" as NSString).draw(at: CGPoint(x: 120, y: 300), withAttributes: body)
            ("学年全体は何人ですか。" as NSString).draw(at: CGPoint(x: 120, y: 350), withAttributes: body)
            ("答え（         ）人" as NSString).draw(at: CGPoint(x: 680, y: 490), withAttributes: body)
            UIColor.lightGray.setStroke()
            for i in 0..<5 {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 100, y: 640 + i * 50))
                path.addLine(to: CGPoint(x: 1100, y: 640 + i * 50))
                path.stroke()
            }
        }
    }()

    @MainActor static func image(for id: String) -> UIImage? {
        id == photoID ? photo : nil
    }
}
