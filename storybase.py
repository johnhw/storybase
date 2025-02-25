from parsimonious.grammar import Grammar
from parsimonious.nodes import NodeVisitor


def preprocess_indentation(text):
    indent_stack = []
    indentation_tokens = []

    lines = text.split("\n")
    for line in lines:
        if line.strip():
            leading_spaces = len(line) - len(line.lstrip())
            if not indent_stack:
                indent_stack.append(leading_spaces)
                indentation_tokens.append("{")
            else:
                if leading_spaces > indent_stack[-1]:
                    indent_stack.append(leading_spaces)
                    indentation_tokens.append("{")
                elif leading_spaces < indent_stack[-1]:
                    while indent_stack and leading_spaces < indent_stack[-1]:
                        indent_stack.pop()
                        indentation_tokens.append("}")
                    if not indent_stack or leading_spaces != indent_stack[-1]:
                        raise IndentationError("Invalid indentation")
        if line.strip():
            indentation_tokens.append(
                line.strip() + "\n"
            )  # append the line without indentation
    while indent_stack:
        indent_stack.pop()
        indentation_tokens.append("}")

    return "".join(indentation_tokens)


p = preprocess_indentation(
    """
def foo():

    if True:
        print('hello')
    else:  
        print('world')
"""
)


print(p)
grammar = Grammar(
    r"""
    program = line+
    line =  assign / expression / label /  quoted / emptyline 
    quoted = ~'`[^`]*`'
    lbrace = '{'
    rbrace = '}'
    comment = ~'#[^\n]*'
    numeral = ~'[0-9]+'
    single_string = ~'[^\']+'
    double_string = ~'"[^"]*"'
    string = double_string / single_string
    integer = numeral+
    float = numeral+ '.' numeral+
    name = ~'[a-zA-Z_][a-zA-Z0-9_]*'
    literal = float / integer / string
    value = literal / name / quoted
    ws = ~"\s*"
    emptyline = ws+
    label = name ':' ws*
    operator = '+' / '-' / '*' / '/' / '%' / '==' / '!=' / '<' / '>' / '<=' / '>=' / 'and' / 'or' / 'not' / 'in' / 'not in' / 'is' / 'is not' / '<<' / '>>' / '&' / '|' / '^' / '~' / '//' / '**'
    op = ws* operator ws*
    expression = (lvalue op expression) / lvalue
    field =  (name '.' field) / name
    index = (name '[' expression ']') / name
    arguments =  (expression ',' arguments) / expression / ''
    function = name '(' arguments ')'
    lvalue = function / index / field / name
    
    assign = lvalue '=' expression
    
    """
)


class StorybaseVisitor(NodeVisitor):
    def visit_quoted(self, node, visited_children):
        return node.text[1:-1]

    def visit_comment(self, node, visited_children):
        return None

    def visit_numeral(self, node, visited_children):
        return int(node.text)

    def visit_single_string(self, node, visited_children):
        return node.text[1:-1]

    def visit_double_string(self, node, visited_children):
        return node.text[1:-1]

    def visit_string(self, node, visited_children):
        return visited_children[0]

    def visit_integer(self, node, visited_children):
        return int(node.text)

    def visit_float(self, node, visited_children):
        return float(node.text)

    def visit_name(self, node, visited_children):
        return node.text

    def visit_literal(self, node, visited_children):
        return visited_children[0]

    def visit_line(self, node, visited_children):
        return visited_children[0]

    def visit_emptyline(self, node, visited_children):
        return None

    def visit_label(self, node, visited_children):
        return visited_children[0]

    def visit_operator(self, node, visited_children):
        return node.text

    def visit_op(self, node, visited_children):
        return visited_children[1]

    def visit_expression(self, node, visited_children):
        if len(visited_children) == 1:
            return visited_children[0]
        else:
            return (visited_children[0], visited_children[1], visited_children[2])

    def visit_field(self, node, visited_children):
        if len(visited_children) == 1:
            return visited_children[0]
        else:
            return (visited_children[0], visited_children[2])

    def visit_index(self, node, visited_children):
        if len(visited_children) == 1:
            return visited_children[0]
        else:
            return (visited_children[0], visited_children[2])

    def visit_arguments(self, node, visited_children):
        if len(visited_children) == 1:
            return visited_children[0]
        else:
            return (visited_children[0], visited_children[2])

    def visit_function(self, node, visited_children):
        return (visited_children[0], visited_children[2])

    def visit_lvalue(self, node, visited_children):
        if len(visited_children) == 1:
            return visited_children[0]
        else:
            return (visited_children[0], visited_children[2])

    def visit_assign(self, node, visited_children):
        return (visited_children[0], visited_children[2])

    def visit_program(self, node, visited_children):
        return visited_children

    def generic_visit(self, node, visited_children):
        return visited_children or node


parsed = grammar.parse("hello()")
print(parsed)

v = StorybaseVisitor()
print(v.visit(parsed))
