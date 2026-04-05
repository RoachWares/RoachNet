using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace RoachNet.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Title = "RoachNet";
        Content = BuildContent();
    }

    private static UIElement BuildContent()
    {
        var root = new Grid
        {
            Background = MakeBrush(8, 10, 11)
        };
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(260) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var rail = new Border
        {
            Background = MakeBrush(16, 20, 23),
            BorderBrush = MakeBrush(34, 40, 43),
            BorderThickness = new Thickness(0, 0, 1, 0)
        };
        var railStack = new StackPanel
        {
            Margin = new Thickness(24)
        };
        railStack.Children.Add(Label("ROACHNET", 12, 180, FontWeights.SemiBold, MakeBrush(24, 245, 119)));
        railStack.Children.Add(TitleText("Native workspace", 26));
        railStack.Children.Add(NavButton("Overview"));
        railStack.Children.Add(NavButton("RoachClaw"));
        railStack.Children.Add(NavButton("Knowledge"));
        railStack.Children.Add(NavButton("Runtime"));
        rail.Child = railStack;
        root.Children.Add(rail);

        var scroller = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        Grid.SetColumn(scroller, 1);

        var contentStack = new StackPanel
        {
            Margin = new Thickness(28)
        };
        contentStack.Children.Add(HeroCard());
        contentStack.Children.Add(MetricStrip());
        contentStack.Children.Add(PanelBlock("RoachClaw", "Local models, contained runtime, and a direct route into the installable content catalog."));
        contentStack.Children.Add(PanelBlock("Dev", "Projects, shell tools, and assistant surfaces grouped into one beta-native lane."));
        contentStack.Children.Add(PanelBlock("Knowledge", "Maps, docs, and course packs install into RoachNet instead of scattering across the system."));
        scroller.Content = contentStack;
        root.Children.Add(scroller);

        return root;
    }

    private static Border HeroCard()
    {
        var stack = new StackPanel();
        stack.Children.Add(Label("OVERVIEW", 12, 180, FontWeights.SemiBold, MakeBrush(24, 245, 119)));
        stack.Children.Add(TitleText("One local control center.", 34));
        stack.Children.Add(Body("RoachClaw, runtime, and installable knowledge in one Windows beta shell."));

        return new Border
        {
            Background = MakeBrush(18, 22, 24),
            BorderBrush = MakeBrush(34, 40, 43),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(24),
            Margin = new Thickness(0, 0, 0, 18),
            Child = stack
        };
    }

    private static Grid MetricStrip()
    {
        var grid = new Grid
        {
            Margin = new Thickness(0, 0, 0, 18)
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var cards = new[]
        {
            FeatureBlock("MODEL", "qwen2.5-coder"),
            FeatureBlock("RUNTIME", "Contained"),
            FeatureBlock("STATE", "Beta")
        };

        for (var i = 0; i < cards.Length; i++)
        {
            Grid.SetColumn(cards[i], i);
            grid.Children.Add(cards[i]);
        }

        return grid;
    }

    private static Border PanelBlock(string title, string body)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 20,
            FontWeight = FontWeights.SemiBold,
            Foreground = MakeBrush(244, 247, 248),
            Margin = new Thickness(0, 0, 0, 8)
        });
        stack.Children.Add(Body(body));

        return new Border
        {
            Background = MakeBrush(18, 22, 24),
            BorderBrush = MakeBrush(34, 40, 43),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(20),
            Margin = new Thickness(0, 0, 0, 14),
            Child = stack
        };
    }

    private static Button NavButton(string text)
    {
        return new Button
        {
            Content = text,
            Margin = new Thickness(0, 0, 0, 10),
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
    }

    private static TextBlock Label(string text, double fontSize, double letterSpacing, FontWeight weight, Brush foreground)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = fontSize,
            LetterSpacing = letterSpacing,
            FontWeight = weight,
            Foreground = foreground,
            Margin = new Thickness(0, 0, 0, 8)
        };
    }

    private static TextBlock TitleText(string text, double size)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = FontWeights.SemiBold,
            Foreground = MakeBrush(244, 247, 248),
            Margin = new Thickness(0, 0, 0, 12)
        };
    }

    private static TextBlock Body(string text)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = 15,
            Foreground = MakeBrush(147, 160, 165),
            TextWrapping = TextWrapping.Wrap
        };
    }

    private static Border FeatureBlock(string label, string value)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 11,
            Foreground = MakeBrush(147, 160, 165),
            Margin = new Thickness(0, 0, 0, 4)
        });
        stack.Children.Add(new TextBlock
        {
            Text = value,
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            Foreground = MakeBrush(244, 247, 248)
        });

        return new Border
        {
            Child = stack,
            Background = MakeBrush(23, 28, 30),
            Padding = new Thickness(16),
            Margin = new Thickness(0, 0, 12, 0)
        };
    }

    private static SolidColorBrush MakeBrush(byte r, byte g, byte b)
    {
        return new SolidColorBrush(ColorHelper.FromArgb(255, r, g, b));
    }
}
