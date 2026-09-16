class ReportBuilder:
    def build(self, rows):
        return rows

def parse_config(path):
    return {}

def render_report(rows):
    b = ReportBuilder()
    return b.build(rows)

parse_config("app.conf")
