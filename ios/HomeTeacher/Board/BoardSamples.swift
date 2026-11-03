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
    ]

    static func content(_ kind: BoardComponent.Kind) -> BoardContent {
        BoardTools.content(toolName: BoardTools.showBoardName, input: Data(json[kind]!.utf8))
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
